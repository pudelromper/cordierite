# vim: set ft=make :

alias upgrade := update
alias fetch := update

# 🐩 Fetch updates for system, flatpaks, and containers
[group("system")]
update:
    #!/usr/bin/bash
    echo "🐩 Fetching updates... Good boy!"
    echo ""

    /usr/libexec/uupd-update | jq -r -R 'fromjson? | [(.title, .msg, .description) | select(.)] | join(" ")'

    echo ""
    echo "🐩 All done! Woof!"

# 🐩 Groom your system - clean up unused packages and cache
[group("system")]
groom:
    #!/usr/bin/bash
    echo "🐩 Time for grooming! Cleaning up your system..."
    echo ""
    echo "Trimming flatpak unused runtimes..."
    flatpak uninstall --unused -y 2>/dev/null || true
    echo ""
    echo "Cleaning package cache..."
    sudo dnf5 clean all 2>/dev/null || true
    echo ""
    echo "Cleaning journal logs older than 7 days..."
    sudo journalctl --vacuum-time=7d 2>/dev/null || true
    echo ""
    echo "🐩 Looking paw-fect! Your system is all groomed."

# Turn automatic updates on or off
_toggle-updates ACTION="prompt":
    #!/usr/bin/bash
    source /usr/lib/ujust/ujust.sh
    CURRENT_STATE="$(systemctl is-enabled uupd.timer)"
    OPTION={{ ACTION }}
    if [ "$OPTION" == "prompt" ]; then
      echo "Automatic updates are currently: ${bold}${CURRENT_STATE^}${normal}"
      echo "Enable or Disable automatic updates?"
      OPTION=$(ugum choose Enable Disable)
    elif [ "$OPTION" == "help" ]; then
      echo "Usage: ujust toggle-updates <option>"
      echo "  <option>: Specify the quick option - 'enable' or 'disable'"
      echo "  Use 'enable' to Enable automatic updates."
      echo "  Use 'disable' to Disable automatic updates."
      exit 0
    fi
    if [ "${OPTION,,}" == "enable" ]; then
      sudo systemctl enable uupd.timer
    elif [ "${OPTION,,}" == "disable" ]; then
      sudo systemctl disable uupd.timer
    fi

alias changelog := changelogs

# Show the stable changelog
[group("system")]
changelogs:
    #!/usr/bin/bash
    CONTENT=$(curl -s https://api.github.com/repos/ublue-os/bazzite/releases/latest | jq -r '.body')
      echo "$CONTENT" | glow -

# Show the testing (pre-release) changelog
[group("system")]
changelogs-testing:
    #!/usr/bin/bash
    CONTENT=$(curl -s https://api.github.com/repos/ublue-os/bazzite/releases | jq -r 'map(select(.prerelease)) | .[0].body')
       echo "$CONTENT" | glow -
