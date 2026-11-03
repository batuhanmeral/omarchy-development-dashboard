pragma ComponentBehavior: Bound
import QtQuick
import qs.Ui as Ui
import "Model.js" as Model

Column {
    id: root
    required property var panel
    readonly property var dashboard: Model.overview(panel.inventory, panel.cfg)
    spacing: panel.gaps.lg
    component Label: Text {
        textFormat: Text.PlainText
        color: root.panel.foreground
        font.family: root.panel.fontFamily
        font.pixelSize: root.panel.fonts.body
        wrapMode: Text.WordWrap
    }
    Label {
        width: parent.width
        visible: !root.panel.sampled
        text: "Collecting your development environment…"
        color: root.panel.dim
    }
    Flow {
        width: parent.width
        spacing: root.panel.gaps.md
        Repeater {
            model: [
                {
                    tab: "Localhost",
                    label: root.dashboard.listening.total + " listening · " + root.dashboard.listening.exposed + " exposed"
                },
                {
                    tab: "Docker",
                    label: root.dashboard.containers.running + "/" + root.dashboard.containers.total + " containers · " + root.dashboard.containers.unhealthy + " unhealthy"
                },
                {
                    tab: "Databases",
                    label: root.dashboard.databases + " databases"
                },
                {
                    tab: "Projects",
                    label: root.dashboard.projects.total + " projects · " + root.dashboard.projects.favorites + " favorites"
                },
                {
                    tab: "Tools",
                    label: root.dashboard.aiTools.available + "/" + root.dashboard.aiTools.total + " AI tools available"
                }
            ]
            Ui.Button {
                required property var modelData
                width: parent.width
                text: modelData.label
                bordered: true
                foreground: root.panel.foreground
                enabled: root.panel.cfg.tabs.indexOf(modelData.tab) >= 0
                onClicked: root.panel.selectTab(modelData.tab)
            }
        }
    }
    Label {
        text: "Favorite projects"
        font.bold: true
    }
    Label {
        width: parent.width
        visible: !root.dashboard.favorites.length
        text: "Favorite a project with F in Projects (5)."
        color: root.panel.dim
    }
    Repeater {
        model: root.dashboard.favorites
        Ui.Button {
            required property var modelData
            width: parent.width
            text: modelData.title + " · " + modelData.badge + " · " + modelData.serviceCount + " services"
            foreground: root.panel.foreground
            bordered: true
            enabled: root.panel.cfg.tabs.indexOf("Projects") >= 0
            onClicked: {
                root.panel.selectTab("Projects");
                root.panel.openDetail(root.panel.visibleRows.findIndex(function (row) {
                    return row.id === modelData.id;
                }));
            }
        }
    }
    Label {
        text: "Exposed services"
        font.bold: true
    }
    Label {
        width: parent.width
        visible: !root.dashboard.exposed.length
        text: "No services exposed beyond localhost."
        color: root.panel.dim
    }
    Repeater {
        model: root.dashboard.exposed
        Ui.Button {
            required property var modelData
            width: parent.width
            text: ":" + modelData.lead + " · " + modelData.title + " · " + modelData.badge
            foreground: root.panel.urgent
            bordered: true
            enabled: root.panel.cfg.tabs.indexOf("Localhost") >= 0
            onClicked: {
                root.panel.selectTab("Localhost");
                root.panel.openDetail(root.panel.visibleRows.findIndex(function (row) {
                    return row.id === modelData.id;
                }));
            }
        }
    }
}
