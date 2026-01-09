import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami
import org.kde.plasma.extras as PlasmaExtras

PlasmoidItem {
    id: root

    property string usernsStatus: "checking..."
    property string cupsStatus: "checking..."
    property string ptraceStatus: "checking..."

    Plasmoid.icon: "security-high"
    Plasmoid.title: "Security Settings"
    Plasmoid.toolTipMainText: "Cordierite Security"
    Plasmoid.toolTipSubText: "Click to configure security settings"
    Plasmoid.status: PlasmaCore.Types.PassiveStatus

    // Data source to run status checks
    PlasmaCore.DataSource {
        id: executable
        engine: "executable"
        connectedSources: []

        onNewData: function(source, data) {
            var stdout = data["stdout"].trim()
            if (source.indexOf("userns") !== -1) {
                root.usernsStatus = stdout.indexOf("restricted") !== -1 ? "Restricted" : "Allowed"
            } else if (source.indexOf("cups") !== -1) {
                root.cupsStatus = stdout.indexOf("disabled") !== -1 ? "Disabled" : "Enabled"
            } else if (source.indexOf("ptrace") !== -1) {
                switch(stdout) {
                    case "0": root.ptraceStatus = "Classic"; break
                    case "1": root.ptraceStatus = "Restricted"; break
                    case "2": root.ptraceStatus = "Admin-only"; break
                    case "3": root.ptraceStatus = "No attach"; break
                    default: root.ptraceStatus = "Unknown"
                }
            }
            disconnectSource(source)
        }
    }

    function refreshStatus() {
        executable.connectSource("semodule -l 2>/dev/null | grep -q '^cordierite-deny-unconfined-userns' && echo 'restricted' || echo 'allowed' # userns")
        executable.connectSource("systemctl is-enabled cups.socket 2>/dev/null | grep -q 'enabled' && echo 'enabled' || echo 'disabled' # cups")
        executable.connectSource("cat /proc/sys/kernel/yama/ptrace_scope 2>/dev/null || echo 'unknown' # ptrace")
    }

    Timer {
        id: refreshTimer
        interval: 10000
        running: true
        repeat: true
        onTriggered: refreshStatus()
    }

    Component.onCompleted: refreshStatus()

    fullRepresentation: PlasmaExtras.Representation {
        Layout.minimumWidth: Kirigami.Units.gridUnit * 18
        Layout.minimumHeight: Kirigami.Units.gridUnit * 14

        header: PlasmaExtras.PlasmoidHeading {
            RowLayout {
                anchors.fill: parent
                Kirigami.Heading {
                    Layout.fillWidth: true
                    level: 1
                    text: "Security Status"
                }
                PlasmaComponents.ToolButton {
                    icon.name: "view-refresh"
                    onClicked: refreshStatus()
                    PlasmaComponents.ToolTip { text: "Refresh status" }
                }
            }
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing

            // Status items
            Kirigami.FormLayout {
                Layout.fillWidth: true

                RowLayout {
                    Kirigami.FormData.label: "User Namespaces:"
                    Kirigami.Icon {
                        source: root.usernsStatus === "Restricted" ? "security-high" : "security-medium"
                        Layout.preferredWidth: Kirigami.Units.iconSizes.small
                        Layout.preferredHeight: Kirigami.Units.iconSizes.small
                    }
                    PlasmaComponents.Label {
                        text: root.usernsStatus
                        color: root.usernsStatus === "Restricted" ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.neutralTextColor
                    }
                }

                RowLayout {
                    Kirigami.FormData.label: "CUPS Printing:"
                    Kirigami.Icon {
                        source: root.cupsStatus === "Disabled" ? "security-high" : "security-medium"
                        Layout.preferredWidth: Kirigami.Units.iconSizes.small
                        Layout.preferredHeight: Kirigami.Units.iconSizes.small
                    }
                    PlasmaComponents.Label {
                        text: root.cupsStatus
                        color: root.cupsStatus === "Disabled" ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.neutralTextColor
                    }
                }

                RowLayout {
                    Kirigami.FormData.label: "Ptrace Scope:"
                    Kirigami.Icon {
                        source: (root.ptraceStatus === "Admin-only" || root.ptraceStatus === "No attach") ? "security-high" : "security-medium"
                        Layout.preferredWidth: Kirigami.Units.iconSizes.small
                        Layout.preferredHeight: Kirigami.Units.iconSizes.small
                    }
                    PlasmaComponents.Label {
                        text: root.ptraceStatus
                        color: (root.ptraceStatus === "Admin-only" || root.ptraceStatus === "No attach") ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.neutralTextColor
                    }
                }
            }

            Kirigami.Separator {
                Layout.fillWidth: true
            }

            PlasmaComponents.Label {
                Layout.fillWidth: true
                text: "Use the button below to toggle security features. Changes require administrator authentication."
                wrapMode: Text.WordWrap
                opacity: 0.7
                font.pointSize: Kirigami.Theme.smallFont.pointSize
            }

            Item { Layout.fillHeight: true }

            PlasmaComponents.Button {
                Layout.fillWidth: true
                text: "Configure Security Settings"
                icon.name: "configure"
                onClicked: {
                    executable.connectSource("/usr/libexec/cordierite-security-settings &")
                    root.expanded = false
                }
            }

            PlasmaComponents.Button {
                Layout.fillWidth: true
                text: "View Detailed Status (Terminal)"
                icon.name: "utilities-terminal"
                onClicked: {
                    executable.connectSource("kde-ptyxis -e ujust security-status &")
                    root.expanded = false
                }
            }
        }
    }

    compactRepresentation: MouseArea {
        id: compactRoot

        property bool wasExpanded: false

        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton

        onPressed: wasExpanded = root.expanded
        onClicked: mouse => {
            if (mouse.button === Qt.MiddleButton) {
                executable.connectSource("/usr/libexec/cordierite-security-settings &")
            } else {
                root.expanded = !wasExpanded
            }
        }

        Kirigami.Icon {
            anchors.fill: parent
            source: "security-high"
            active: parent.containsMouse
        }
    }
}
