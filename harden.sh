#!/bin/bash

# Color definitions
RED="\e[31m"
GREEN="\e[32m"
BOLD="\e[1m"
ENDCOLOR="\e[0m"

# Function to handle colors
print_color() {
    local color=$1
    local text=$2
    if [ "$NO_COLOR" = true ]; then
        echo "$text"
    else
        echo -e "${color}${text}${ENDCOLOR}"
    fi
}

# Modified usage
usage() {
    echo "Usage: $0 [-n NAMESPACE | -A] [-o OUTPUT_FILE]"
    echo "  -n NAMESPACE   : Check pods in specific namespace"
    echo "  -A            : Check pods in all namespaces"
    echo "  -o OUTPUT_FILE : Write to file instead of stdout"
    echo "  --no-color    : Disable color output"
    exit 1
}

# Function to format JSON with colored output
format_json() {
    while IFS= read -r line; do
        if [[ $line =~ '"runAsNonRoot": true' ]]; then
            print_color "$GREEN" "    \"runAsNonRoot\": true,"
        elif [[ $line =~ '"runAsNonRoot": false' ]]; then
            print_color "$RED" "    \"runAsNonRoot\": false,"
        elif [[ $line =~ '"readOnlyRootFilesystem": true' ]]; then
            print_color "$GREEN" "    \"readOnlyRootFilesystem\": true,"
        elif [[ $line =~ '"readOnlyRootFilesystem": false' || $line =~ '"readOnlyRootFilesystem": null' ]]; then
            print_color "$RED" "    \"readOnlyRootFilesystem\": false,"
        elif [[ $line =~ '"securityContext": \{\}' ]]; then
            echo "    \"securityContext\": {"
            print_color "$RED" "    \"readOnlyRootFilesystem\": false"
            echo "    },"
        else
            echo "    $line"
        fi
    done
}

# Function to check container capabilities
check_capabilities() {
    # Get the input parameters
    local pod=$1
    local namespace=$2
    local container=$3

    echo "Container Capabilities:"

    # Get the container's security capabilities using oc and jq
    # 1. Get the pod details in JSON format
    # 2. Find the specific container by name
    # 3. Extract its capabilities (if any)
    #  oc get pod openshift-gitops-applicationset-controller-655d75cc75-rlhfg -o json | \
    # jq -r --arg container "argocd-applicationset-controller" '.spec.containers[] | \
    # select(.name == $container) | .securityContext.capabilities'
    local capabilities=$(oc get pod $pod -n $namespace -o json | \
        jq -r --arg container "$container" \
        '.spec.containers[] |
         select(.name == $container) |
         .securityContext.capabilities')

    # If no capabilities are specified, this is good
    if [ -z "$capabilities" ]; then
        print_color "$GREEN" "  No additional capabilities specified"
        return
    fi

    # List of capabilities we consider dangerous
    local DANGEROUS_CAPABILITIES=(
        "CAP_SYS_ADMIN"
        "CAP_NET_ADMIN"
        "CAP_SYS_PTRACE"
    )

    # Convert dangerous capabilities to jq-friendly format
    local dangerous_list=$(printf " . == \"%s\" or" "${DANGEROUS_CAPABILITIES[@]}")
    dangerous_list=${dangerous_list% or}  # Remove the last 'or'

    # Check for dangerous capabilities
    # 1. Look at the 'add' field in capabilities
    # 2. Filter for dangerous capabilities
    # 3. Join them with commas for display
    local dangerous_found=$(echo "$capabilities" | \
        jq -r ".add // [] |
               map(select($dangerous_list)) |
               join(\", \")")

    # If dangerous capabilities were found, show them in red
    # Otherwise, show green for safe configuration
    if [ -n "$dangerous_found" ]; then
        print_color "$RED" "  Dangerous capabilities found: $dangerous_found"
    else
        print_color "$GREEN" "  No dangerous capabilities found"
    fi
}


# Function to check service account token mounting
check_sa_token() {
    local pod=$1
    local namespace=$2

    echo "Service Account Token Mount:"

    # First check if automountServiceAccountToken is explicitly set at pod level
    local pod_automount=$(oc get pod $pod -n $namespace -o json | \
        jq -r '.spec.automountServiceAccountToken')

    # If pod level is false, we can return immediately as this takes precedence
    if [ "$pod_automount" = "false" ]; then
        print_color "$GREEN" "  Service account token mounting explicitly disabled at pod level"
        return
    fi

    # Get the service account name
    local sa_name=$(oc get pod $pod -n $namespace -o json | \
        jq -r '.spec.serviceAccountName // "default"')

    # Check service account level setting
    local sa_automount=$(oc get serviceaccount $sa_name -n $namespace -o json 2>/dev/null | \
        jq -r '.automountServiceAccountToken')

    # Determine final status
    if [ "$pod_automount" = "true" ]; then
        print_color "$RED" "  Service account token explicitly enabled at pod level"
    elif [ "$sa_automount" = "false" ]; then
        print_color "$GREEN" "  Service account token disabled at service account level"
    elif [ "$pod_automount" = "null" ] && [ "$sa_automount" = "null" ]; then
        print_color "$RED" "  Service account token mounting defaulted to enabled (no explicit settings)"
    else
        print_color "$RED" "  Service account token is mounted (inherited from higher level settings)"
    fi
}
# Function to check pods in a namespace
check_namespace() {
    local namespace=$1
    print_color "$BOLD" "Checking namespace: $namespace"
    print_color "$BOLD" "=============================="
    echo

    oc get pods -n $namespace -o json | jq -r '.items[] | select(.status.phase=="Running") | .metadata.name' | while read pod; do
        print_color "$BOLD" "=== Pod: $pod ==="

        echo -e "\nContainer Security Contexts:"
        
        # Retrieve the pod's JSON definition and extract the security context for each container
        # If the securityContext is null, set "readOnlyRootFilesystem" to false by default
        # Otherwise, merge the existing securityContext with a default "readOnlyRootFilesystem: false"
        # if it is not explicitly defined
        oc get pod $pod -n $namespace -o json | jq -r '.spec.containers[] | {
            name: .name,  # Extract the container name
            securityContext: (if .securityContext == null then
                {"readOnlyRootFilesystem": false}  # Default value if securityContext is missing
            else
                (.securityContext + if .securityContext.readOnlyRootFilesystem == null then
                    {"readOnlyRootFilesystem": false}  # Add default if readOnlyRootFilesystem is not defined
                else
                    {}
                end)
            end)
        }' | format_json  # Format the JSON output for better readability


        # Check actual user IDs
        echo -e "\nContainer User IDs:"
        for container in $(oc get pod $pod -n $namespace -o jsonpath='{.spec.containers[*].name}'); do
            echo -n "Container $container: "
            uid=$(oc exec $pod -n $namespace -c $container -- id -u 2>/dev/null)
            if [ "$uid" = "0" ]; then
                print_color "$RED" "UID=$uid (root)"
            else
                print_color "$GREEN" "UID=$uid"
            fi
        done

        # Check container capabilities and permissions
        echo -e "\nContainer Capabilities and Permissions:"
        for container in $(oc get pod $pod -n $namespace -o jsonpath='{.spec.containers[*].name}'); do
            echo "Container $container:"
            check_capabilities "$pod" "$namespace" "$container"
        done

        # Check service account token configuration
        echo -e "\nService Account Token Configuration:"
        check_sa_token "$pod" "$namespace"

        print_color "$BOLD" "-------------------"
        echo
    done
}

# Initialize variables
NAMESPACE=""
ALL_NAMESPACES=false
NO_COLOR=false
OUTPUT_FILE=""

# Parse command line arguments
# namespace: -n NAMESPACE
# all namespaces: -A (no argument so no :)
# output file: -o OUTPUT_FILE
# no color: --no-color
while getopts ":n:Ao:-:" opt; do
    case $opt in
        n)
            NAMESPACE=$OPTARG
            ;;
        A)
            ALL_NAMESPACES=true
            ;;
        o)
            OUTPUT_FILE=$OPTARG
            NO_COLOR=true
            ;;
        -)
            case "${OPTARG}" in
                no-color)
                    NO_COLOR=true
                    ;;
                *)
                    usage
                    ;;
            esac
            ;;
        *)
            usage
            ;;
    esac
done

# Check if no arguments provided
if [ $OPTIND -eq 1 ]; then
    usage
fi

# Function to execute and optionally redirect to file
execute_check() {
    if [ -n "$OUTPUT_FILE" ]; then
        if [ "$ALL_NAMESPACES" = true ]; then
            for ns in $(oc get namespaces -o jsonpath='{.items[*].metadata.name}'); do
                check_namespace $ns >> "$OUTPUT_FILE"
            done
        else
            check_namespace $NAMESPACE >> "$OUTPUT_FILE"
        fi
        echo "Output written to $OUTPUT_FILE"
    else
        if [ "$ALL_NAMESPACES" = true ]; then
            for ns in $(oc get namespaces -o jsonpath='{.items[*].metadata.name}'); do
                check_namespace $ns
            done
        else
            check_namespace $NAMESPACE
        fi
    fi
}

# Execute based on arguments
if [ "$ALL_NAMESPACES" = true ]; then
    execute_check
else
    # Check specific namespace
    if ! oc get namespace $NAMESPACE >/dev/null 2>&1; then
        print_color "$RED" "Error: Namespace '$NAMESPACE' does not exist"
        exit 1
    fi
    execute_check
fi