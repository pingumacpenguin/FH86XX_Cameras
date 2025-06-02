#!/bin/bash

# --- Camera Settings ---
CAMERA_IP="${1:-ipcam1}" # Use first argument or default to 'ipcam1'
ONVIF_PORT="${2:-6688}"  # Use second argument or default to '6688'

# !!! CHANGE THESE CREDENTIALS TO THE CORRECT ONES FOR YOUR CAMERA !!!
USERNAME="admin"
PASSWORD="admin123456"
# ---------------------------------

if ! command -v xmllint &> /dev/null; then
    echo "ERROR: xmllint not found. Please install it." >&2
    echo "Debian/Ubuntu: sudo apt-get install libxml2-utils" >&2
    echo "Fedora/CentOS: sudo yum install libxml2" >&2
    exit 1
fi
if ! command -v mktemp &> /dev/null; then
    echo "ERROR: mktemp not found. Please install it (usually part of coreutils)." >&2
    exit 1
fi

# Function to make ONVIF SOAP calls with detailed debugging
# Arguments:
# 1: Service XAddr URL
# 2: SOAP Action
# 3: SOAP Request Body
# 4: Description of the call (for logging)
# 5: Authentication type ("basic", "digest", or "anyauth")
call_onvif_service() {
    local service_xaddr="$1"
    local soap_action="$2"
    local soap_request_body="$3"
    local call_description="$4"
    local auth_type="$5"
    local temp_response_file
    local curl_verbose_output_file
    local auth_curl_option

    if [ "$auth_type" == "basic" ]; then
        auth_curl_option="--basic"
    elif [ "$auth_type" == "digest" ]; then
        auth_curl_option="--digest"
    elif [ "$auth_type" == "anyauth" ]; then
        auth_curl_option="--anyauth"
    else
        echo "INTERNAL ERROR: Invalid authentication type '$auth_type' provided to call_onvif_service." >&2
        return 1
    fi

    temp_response_file=$(mktemp)
    curl_verbose_output_file=$(mktemp)

    echo "" >&2
    echo "=================================================================================" >&2
    echo ">>> STARTING ONVIF CALL: $call_description (Using ${auth_type^^} AUTHENTICATION)" >&2
    echo "---------------------------------------------------------------------------------" >&2
    echo "ENDPOINT    : $service_xaddr" >&2
    echo "SOAPAction  : \"$soap_action\"" >&2
    echo "---------------------------------------------------------------------------------" >&2

    http_status_code=$(curl --silent --show-error "$auth_curl_option" -u "$USERNAME:$PASSWORD" \
         --header "Content-Type: application/soap+xml; charset=utf-8" \
         --header "SOAPAction: \"$soap_action\"" \
         --data "$soap_request_body" \
         --verbose --stderr "$curl_verbose_output_file" \
         -o "$temp_response_file" \
         -w "%{http_code}" \
         "$service_xaddr")

    curl_exit_code=$?

    echo "CURL VERBOSE OUTPUT (from file $curl_verbose_output_file):" >&2
    cat "$curl_verbose_output_file" >&2
    echo "" >&2
    echo "---------------------------------------------------------------------------------" >&2
    echo "HTTP STATUS RETURNED BY CURL: $http_status_code" >&2
    echo "CURL EXIT CODE              : $curl_exit_code" >&2
    echo "---------------------------------------------------------------------------------" >&2
    echo "RESPONSE BODY (from file $temp_response_file):" >&2
    if [ -s "$temp_response_file" ]; then
        (xmllint --format "$temp_response_file" 2>/dev/null || cat "$temp_response_file") >&2
    else
        echo "[RESPONSE BODY EMPTY OR NOT RECEIVED]" >&2
    fi
    echo "" >&2
    echo "<<< END OF ONVIF CALL: $call_description" >&2
    echo "=================================================================================" >&2
    echo "" >&2

    if [ -f "$temp_response_file" ] && [ "$curl_exit_code" -eq 0 ] && [ "$http_status_code" -eq 200 ]; then
        cat "$temp_response_file"
        rm "$temp_response_file" "$curl_verbose_output_file"
    else
        
        rm -f "$temp_response_file" "$curl_verbose_output_file"
        return 1
    fi
}

echo "--- [STEP 1: Getting Device Capabilities (GetCapabilities)] ---" >&2 # Step message to stderr
DEVICE_SERVICE_INITIAL_XADDR="http://$CAMERA_IP:$ONVIF_PORT/onvif/device_service"
GET_CAPABILITIES_SOAP_ACTION="http://www.onvif.org/ver10/device/wsdl/GetCapabilities"
GET_CAPABILITIES_REQUEST_BODY='<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
                                 <s:Body>
                                   <GetCapabilities xmlns="http://www.onvif.org/ver10/device/wsdl">
                                     <Category>All</Category>
                                   </GetCapabilities>
                                 </s:Body>
                               </s:Envelope>'

capabilities_result=$(call_onvif_service "$DEVICE_SERVICE_INITIAL_XADDR" "$GET_CAPABILITIES_SOAP_ACTION" "$GET_CAPABILITIES_REQUEST_BODY" "GetCapabilities" "basic")

if [ -z "$capabilities_result" ]; then
    echo "CRITICAL ERROR: Failed to get capabilities or response was empty (HTTP not 200 or curl error). Check the CURL VERBOSE OUTPUT and RESPONSE BODY above for the 'GetCapabilities' call." >&2
    exit 1
fi

# Extract XAddrs for Media, PTZ, and Events services
MEDIA_XADDR=$(echo "$capabilities_result" | xmllint --xpath "string(//*[local-name()='Capabilities']/*[local-name()='Media']/*[local-name()='XAddr'])" - 2>/dev/null)
PTZ_XADDR=$(echo "$capabilities_result" | xmllint --xpath "string(//*[local-name()='Capabilities']/*[local-name()='PTZ']/*[local-name()='XAddr'])" - 2>/dev/null)
EVENTS_XADDR=$(echo "$capabilities_result" | xmllint --xpath "string(//*[local-name()='Capabilities']/*[local-name()='Events']/*[local-name()='XAddr'])" - 2>/dev/null) # Extract Events XAddr

# --- Media Service Exploration ---
if [ -n "$MEDIA_XADDR" ]; then
    echo "--- [STEP 2: Media Service Exploration (XAddr: $MEDIA_XADDR)] ---" >&2
    echo "--- [STEP 2.1: Getting Media Profiles (GetProfiles)] ---" >&2
    GET_PROFILES_SOAP_ACTION="http://www.onvif.org/ver10/media/wsdl/GetProfiles"
    GET_PROFILES_REQUEST_BODY='<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:trt="http://www.onvif.org/ver10/media/wsdl">
                                 <s:Header/>
                                 <s:Body>
                                   <trt:GetProfiles/>
                                 </s:Body>
                               </s:Envelope>'
    get_profiles_result=$(call_onvif_service "$MEDIA_XADDR" "$GET_PROFILES_SOAP_ACTION" "$GET_PROFILES_REQUEST_BODY" "GetProfiles" "anyauth")

    if [ -n "$get_profiles_result" ]; then
        echo "--- [STEP 2.2: Getting Stream URIs for each profile (GetStreamUri)] ---" >&2
        PROFILE_TOKENS_LINES=$(echo "$get_profiles_result" | xmllint --xpath "//*[local-name()='Profiles']/@token" - 2>/dev/null)
        PROFILE_TOKENS=$(echo "$PROFILE_TOKENS_LINES" | sed 's/token="\([^"]*\)"/\1 /g')

        if [ -n "$PROFILE_TOKENS" ]; then
            for token in $PROFILE_TOKENS; do
                echo "  Processing ProfileToken: $token" >&2
                GET_STREAM_URI_SOAP_ACTION="http://www.onvif.org/ver10/media/wsdl/GetStreamUri"
                GET_STREAM_URI_REQUEST_BODY_TEMPLATE='<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:trt="http://www.onvif.org/ver10/media/wsdl" xmlns:tt="http://www.onvif.org/ver10/schema">
                                                      <s:Header/>
                                                      <s:Body>
                                                        <trt:GetStreamUri>
                                                          <trt:StreamSetup>
                                                            <tt:Stream>RTP-Unicast</tt:Stream>
                                                            <tt:Transport>
                                                              <tt:Protocol>TCP</tt:Protocol>
                                                            </tt:Transport>
                                                          </trt:StreamSetup>
                                                          <trt:ProfileToken>%PROFILE_TOKEN%</trt:ProfileToken>
                                                        </trt:GetStreamUri>
                                                      </s:Body>
                                                    </s:Envelope>'
                get_stream_uri_request_body=${GET_STREAM_URI_REQUEST_BODY_TEMPLATE//%PROFILE_TOKEN%/$token}
                
                call_onvif_service "$MEDIA_XADDR" "$GET_STREAM_URI_SOAP_ACTION" "$get_stream_uri_request_body" "GetStreamUri for token $token" "anyauth"
            done
        else
            echo "  No ProfileTokens found in GetProfiles response. The GetProfiles response may have failed or was empty." >&2
        fi
    else
         echo "  Failed to get GetProfiles or response was empty. Skipping GetStreamUri." >&2
    fi
else
    echo "--- [WARNING: Media Service XAddr not found in Capabilities. Skipping media exploration.] ---" >&2
fi

# --- PTZ Service Exploration ---
if [ -n "$PTZ_XADDR" ]; then
    echo "--- [STEP 3: PTZ Service Exploration (XAddr: $PTZ_XADDR)] ---" >&2
    echo "--- [STEP 3.1: Getting PTZ Nodes (GetNodes)] ---" >&2
    GET_NODES_SOAP_ACTION="http://www.onvif.org/ver20/ptz/wsdl/GetNodes"
    GET_NODES_REQUEST_BODY='<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:tptz="http://www.onvif.org/ver20/ptz/wsdl">
                              <s:Header/>
                              <s:Body>
                                <tptz:GetNodes/>
                              </s:Body>
                            </s:Envelope>'
    call_onvif_service "$PTZ_XADDR" "$GET_NODES_SOAP_ACTION" "$GET_NODES_REQUEST_BODY" "GetNodes (PTZ)" "anyauth"

    echo "--- [STEP 3.2: Getting PTZ Configurations (GetConfigurations)] ---" >&2
    GET_PTZ_CONFIGS_SOAP_ACTION="http://www.onvif.org/ver20/ptz/wsdl/GetConfigurations"
    GET_PTZ_CONFIGS_REQUEST_BODY='<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:tptz="http://www.onvif.org/ver20/ptz/wsdl">
                                    <s:Header/>
                                    <s:Body>
                                      <tptz:GetConfigurations/>
                                    </s:Body>
                                  </s:Envelope>'
    call_onvif_service "$PTZ_XADDR" "$GET_PTZ_CONFIGS_SOAP_ACTION" "$GET_PTZ_CONFIGS_REQUEST_BODY" "GetConfigurations (PTZ)" "anyauth"
else
    echo "--- [WARNING: PTZ Service XAddr not found in Capabilities (or camera does not support PTZ). Skipping PTZ exploration.] ---" >&2
fi

# --- STEP 4: Event Service Exploration ---
if [ -n "$EVENTS_XADDR" ]; then
    echo "--- [STEP 4: Event Service Exploration (XAddr: $EVENTS_XADDR)] ---" >&2
    echo "--- [STEP 4.1: Getting Event Properties (GetEventProperties)] ---" >&2
    GET_EVENT_PROPERTIES_SOAP_ACTION="http://www.onvif.org/ver10/events/wsdl/GetEventProperties"
    GET_EVENT_PROPERTIES_REQUEST_BODY='<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:tev="http://www.onvif.org/ver10/events/wsdl">
                                        <s:Header/>
                                        <s:Body>
                                          <tev:GetEventProperties/>
                                        </s:Body>
                                      </s:Envelope>'
    event_properties_result=$(call_onvif_service "$EVENTS_XADDR" "$GET_EVENT_PROPERTIES_SOAP_ACTION" "$GET_EVENT_PROPERTIES_REQUEST_BODY" "GetEventProperties" "anyauth")

    if [ -z "$event_properties_result" ]; then
        echo "  Failed to get GetEventProperties or response was empty." >&2
    else
        echo "  GetEventProperties response received (see details in verbose output and response body above)." >&2
    fi
else
    echo "--- [WARNING: Event Service XAddr not found in Capabilities. Skipping event exploration.] ---" >&2
fi


echo "" >&2
echo "--- [ONVIF DEBUG SCRIPT COMPLETED] ---" >&2
