# vim: set ft=make :

# Cordierite Security Hardening Commands
# These commands help manage security features like user namespace restrictions

# Toggle user namespace creation for the container domain (Distrobox/Podman)
[group("security")]
set-container-userns ACTION="":
    #!/usr/bin/bash
    source /usr/lib/ujust/ujust.sh

    SELINUX_MODULE="cordierite-deny-container-userns"
    MODULE_PATH="/usr/share/cordierite/selinux/${SELINUX_MODULE}"

    # Check current status
    CURRENT_STATUS="allowed"
    if semodule -l 2>/dev/null | grep -q "^${SELINUX_MODULE}"; then
        CURRENT_STATUS="denied"
    fi

    OPTION="{{ ACTION }}"
    if [ "$OPTION" == "help" ]; then
        echo "Usage: ujust set-container-userns <on|off>"
        echo ""
        echo "Controls user namespace creation for container domains (Podman, Distrobox)."
        echo ""
        echo "  on  - Allow container domain to create user namespaces (needed for Distrobox)"
        echo "  off - Deny container domain from creating user namespaces (more secure)"
        echo ""
        echo "Current status: Container userns is ${CURRENT_STATUS}"
        echo ""
        echo "${yellow}Note: Enabling this is required for Distrobox but is a security degradation.${normal}"
        exit 0
    elif [ -z "$OPTION" ]; then
        echo "${bold}Container Domain User Namespace Configuration${normal}"
        echo ""
        echo "User namespaces allow unprivileged containers to create isolated environments."
        echo "This is required for Distrobox and rootless Podman containers."
        echo ""
        if [ "$CURRENT_STATUS" == "allowed" ]; then
            echo "Current status: ${green}Allowed${normal}"
        else
            echo "Current status: ${red}Denied${normal} (more secure)"
        fi
        echo ""
        echo "${yellow}Warning: Allowing userns for containers is a security degradation.${normal}"
        echo ""
        OPTION=$(ugum choose "on - Allow (for Distrobox)" "off - Deny (secure)" "Exit without changes")
    fi

    case "$OPTION" in
        on*|allow*)
            echo "Allowing user namespace creation for container domain..."
            if semodule -l 2>/dev/null | grep -q "^${SELINUX_MODULE}"; then
                sudo semodule -r "${SELINUX_MODULE}" 2>/dev/null || true
            fi
            echo "${green}Container domain can now create user namespaces.${normal}"
            echo "Distrobox and rootless Podman should now work."
            ;;
        off*|deny*)
            echo "Denying user namespace creation for container domain..."
            if [ -f "${MODULE_PATH}.pp" ]; then
                sudo semodule -i "${MODULE_PATH}.pp"
                echo "${red}Container domain is now denied user namespace creation.${normal}"
            else
                echo "${yellow}SELinux module not found. Compiling...${normal}"
                if [ -f "${MODULE_PATH}.te" ]; then
                    TMPDIR=$(mktemp -d)
                    checkmodule -M -m -o "${TMPDIR}/${SELINUX_MODULE}.mod" "${MODULE_PATH}.te"
                    semodule_package -o "${TMPDIR}/${SELINUX_MODULE}.pp" -m "${TMPDIR}/${SELINUX_MODULE}.mod"
                    sudo semodule -i "${TMPDIR}/${SELINUX_MODULE}.pp"
                    rm -rf "${TMPDIR}"
                    echo "${red}Container domain is now denied user namespace creation.${normal}"
                else
                    echo "${red}Error: SELinux policy source not found.${normal}"
                    exit 1
                fi
            fi
            ;;
        *)
            echo "No changes made."
            ;;
    esac

# Toggle user namespace creation for the unconfined domain (general applications)
[group("security")]
set-unconfined-userns ACTION="":
    #!/usr/bin/bash
    source /usr/lib/ujust/ujust.sh

    SELINUX_MODULE="cordierite-deny-unconfined-userns"
    MODULE_PATH="/usr/share/cordierite/selinux/${SELINUX_MODULE}"

    # Check current status
    CURRENT_STATUS="allowed"
    if semodule -l 2>/dev/null | grep -q "^${SELINUX_MODULE}"; then
        CURRENT_STATUS="denied"
    fi

    OPTION="{{ ACTION }}"
    if [ "$OPTION" == "help" ]; then
        echo "Usage: ujust set-unconfined-userns <on|off>"
        echo ""
        echo "Controls user namespace creation for unconfined processes."
        echo ""
        echo "  on  - Allow unconfined processes to create user namespaces"
        echo "  off - Deny unconfined processes from creating user namespaces (more secure)"
        echo ""
        echo "Current status: Unconfined userns is ${CURRENT_STATUS}"
        echo ""
        echo "${yellow}Note: Some applications like Bubblejail require user namespaces.${normal}"
        exit 0
    elif [ -z "$OPTION" ]; then
        echo "${bold}Unconfined Domain User Namespace Configuration${normal}"
        echo ""
        echo "User namespaces allow unprivileged processes to create isolated environments."
        echo "Denying this improves security but may break some applications."
        echo ""
        if [ "$CURRENT_STATUS" == "allowed" ]; then
            echo "Current status: ${yellow}Allowed${normal}"
        else
            echo "Current status: ${green}Denied${normal} (more secure)"
        fi
        echo ""
        echo "${yellow}Warning: Allowing userns for unconfined processes is a security degradation.${normal}"
        echo ""
        OPTION=$(ugum choose "on - Allow (less secure)" "off - Deny (secure)" "Exit without changes")
    fi

    case "$OPTION" in
        on*|allow*)
            echo "Allowing user namespace creation for unconfined domain..."
            if semodule -l 2>/dev/null | grep -q "^${SELINUX_MODULE}"; then
                sudo semodule -r "${SELINUX_MODULE}" 2>/dev/null || true
            fi
            echo "${yellow}Unconfined domain can now create user namespaces.${normal}"
            echo "This is a security degradation."
            ;;
        off*|deny*)
            echo "Denying user namespace creation for unconfined domain..."
            if [ -f "${MODULE_PATH}.pp" ]; then
                sudo semodule -i "${MODULE_PATH}.pp"
                echo "${green}Unconfined domain is now denied user namespace creation.${normal}"
            else
                echo "${yellow}SELinux module not found. Compiling...${normal}"
                if [ -f "${MODULE_PATH}.te" ]; then
                    TMPDIR=$(mktemp -d)
                    checkmodule -M -m -o "${TMPDIR}/${SELINUX_MODULE}.mod" "${MODULE_PATH}.te"
                    semodule_package -o "${TMPDIR}/${SELINUX_MODULE}.pp" -m "${TMPDIR}/${SELINUX_MODULE}.mod"
                    sudo semodule -i "${TMPDIR}/${SELINUX_MODULE}.pp"
                    rm -rf "${TMPDIR}"
                    echo "${green}Unconfined domain is now denied user namespace creation.${normal}"
                else
                    echo "${red}Error: SELinux policy source not found.${normal}"
                    exit 1
                fi
            fi
            ;;
        *)
            echo "No changes made."
            ;;
    esac

# Toggle CUPS printing service
[group("security")]
set-cups-service ACTION="":
    #!/usr/bin/bash
    source /usr/lib/ujust/ujust.sh

    # Check current status
    CURRENT_STATUS="unknown"
    if systemctl is-enabled cups.socket 2>/dev/null | grep -q "enabled"; then
        CURRENT_STATUS="enabled"
    elif systemctl is-enabled cups.socket 2>/dev/null | grep -q "disabled"; then
        CURRENT_STATUS="disabled"
    fi

    OPTION="{{ ACTION }}"
    if [ "$OPTION" == "help" ]; then
        echo "Usage: ujust set-cups-service <on|off>"
        echo ""
        echo "Controls the CUPS printing service."
        echo ""
        echo "  on  - Enable CUPS (required for printing)"
        echo "  off - Disable CUPS (more secure if you don't need printing)"
        echo ""
        echo "Current status: CUPS is ${CURRENT_STATUS}"
        echo ""
        echo "${yellow}Note: CUPS has had security vulnerabilities. Disable if not needed.${normal}"
        exit 0
    elif [ -z "$OPTION" ]; then
        echo "${bold}CUPS Printing Service Configuration${normal}"
        echo ""
        echo "CUPS provides printing support but has historically had security issues."
        echo "Disable it if you don't need to print from this system."
        echo ""
        if [ "$CURRENT_STATUS" == "enabled" ]; then
            echo "Current status: ${yellow}Enabled${normal}"
        else
            echo "Current status: ${green}Disabled${normal} (more secure)"
        fi
        echo ""
        OPTION=$(ugum choose "on - Enable (for printing)" "off - Disable (secure)" "Exit without changes")
    fi

    case "$OPTION" in
        on*|enable*)
            echo "Enabling CUPS printing service..."
            sudo systemctl enable --now cups.socket cups.service 2>/dev/null || true
            echo "${yellow}CUPS is now enabled.${normal}"
            echo "You can now use printers."
            ;;
        off*|disable*)
            echo "Disabling CUPS printing service..."
            sudo systemctl disable --now cups.socket cups.service cups.path 2>/dev/null || true
            echo "${green}CUPS is now disabled.${normal}"
            echo "Printing will not work until re-enabled."
            ;;
        *)
            echo "No changes made."
            ;;
    esac

# Display current security status
[group("security")]
security-status:
    #!/usr/bin/bash
    source /usr/lib/ujust/ujust.sh

    echo "${bold}Cordierite Security Status${normal}"
    echo ""

    # Check unconfined userns status
    if semodule -l 2>/dev/null | grep -q "^cordierite-deny-unconfined-userns"; then
        echo "Unconfined domain userns: ${green}Denied${normal} (secure)"
    else
        echo "Unconfined domain userns: ${yellow}Allowed${normal}"
    fi

    # Check container userns status
    if semodule -l 2>/dev/null | grep -q "^cordierite-deny-container-userns"; then
        echo "Container domain userns:  ${green}Denied${normal} (secure)"
    else
        echo "Container domain userns:  ${yellow}Allowed${normal}"
    fi

    # Check flatpak status
    if semodule -l 2>/dev/null | grep -q "^cordierite-allow-flatpak-userns"; then
        echo "Flatpak domain userns:    ${green}Allowed${normal} (required for Flatpak)"
    else
        echo "Flatpak domain userns:    Uses system default"
    fi

    # Check CUPS status
    echo ""
    if systemctl is-enabled cups.socket 2>/dev/null | grep -q "enabled"; then
        echo "CUPS printing service:    ${yellow}Enabled${normal}"
    else
        echo "CUPS printing service:    ${green}Disabled${normal} (secure)"
    fi

    # Show ptrace status
    PTRACE_SCOPE=$(cat /proc/sys/kernel/yama/ptrace_scope 2>/dev/null || echo "unknown")
    case "$PTRACE_SCOPE" in
        0) echo "Ptrace scope:             ${red}Classic${normal} (insecure)" ;;
        1) echo "Ptrace scope:             ${yellow}Restricted${normal}" ;;
        2) echo "Ptrace scope:             ${green}Admin-only${normal} (secure)" ;;
        3) echo "Ptrace scope:             ${green}No attach${normal} (most secure)" ;;
        *) echo "Ptrace scope:             Unknown" ;;
    esac

    echo ""
    echo "Use 'ujust set-unconfined-userns' to toggle unconfined domain"
    echo "Use 'ujust set-container-userns' to toggle container domain"
    echo "Use 'ujust set-cups-service' to toggle CUPS printing"

