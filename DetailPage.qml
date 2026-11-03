pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts
import qs.Commons
import qs.Ui as Ui
import "Model.js" as Model

Column {
    id: root
    required property var panel
    component Label: Text {
        textFormat: Text.PlainText
        color: root.panel.foreground
        font.family: root.panel.fontFamily
        font.pixelSize: root.panel.fonts.body
    }

    component Badge: Ui.BorderSurface {
        id: badge
        property string text: ""
        property color tint: root.panel.dim
        implicitWidth: badgeLabel.implicitWidth + Style.space(12)
        implicitHeight: badgeLabel.implicitHeight + Style.space(4)
        radius: Style.cornerRadius
        color: Util.alpha(tint, 0.16)
        border.width: 1
        border.color: Util.alpha(tint, 0.6)
        Label {
            id: badgeLabel
            anchors.centerIn: parent
            text: badge.text
            color: badge.tint
            font.pixelSize: root.panel.fonts.caption
            font.bold: true
        }
    }

    width: parent.width
    visible: root.panel.view === "detail" || root.panel.view === "logs"
    spacing: root.panel.gaps.xl

    RowLayout {
        width: parent.width
        spacing: root.panel.gaps.lg
        Ui.PanelActionButton {
            // nf-md-arrow_left
            iconText: "\u{f004d}"
            tooltipText: root.panel.view === "logs" ? "Back to details (Esc)" : "Back to the list (Esc)"
            foreground: root.panel.foreground
            bordered: true
            Layout.alignment: Qt.AlignVCenter
            onClicked: root.panel.back()
        }
        ColumnLayout {
            Layout.fillWidth: true
            Layout.minimumWidth: 0
            spacing: Style.space(1)
            Label {
                Layout.fillWidth: true
                text: (root.panel.selectedRow.lead ? ":" + root.panel.selectedRow.lead + "  " : "") + (root.panel.selectedRow.title || "")
                font.pixelSize: root.panel.fonts.subtitle
                font.bold: true
                elide: Text.ElideMiddle
            }
            Label {
                Layout.fillWidth: true
                text: root.panel.view === "logs" ? "Last 100 log lines" : root.panel.selectedRow.subtitle || ""
                color: root.panel.dim
                font.pixelSize: root.panel.fonts.caption
                elide: Text.ElideRight
            }
        }
        Badge {
            Layout.alignment: Qt.AlignVCenter
            text: root.panel.selectedRow.badge || ""
            tint: root.panel.toneColor(root.panel.selectedRow.tone || "dim")
        }
    }

    Ui.PanelSeparator {
        foreground: root.panel.foreground
    }

    // Facts: click a value to copy it.
    Column {
        width: parent.width
        visible: root.panel.view === "detail"
        spacing: Style.space(2)
        Repeater {
            model: root.panel.selectedFacts
            Ui.CursorSurface {
                id: fact
                required property var modelData
                width: parent.width
                implicitHeight: Math.max(factValue.implicitHeight, factLabel.implicitHeight) + root.panel.gaps.lg
                hasCursor: factMouse.containsMouse && fact.modelData.copy !== ""
                foreground: root.panel.foreground
                MouseArea {
                    id: factMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: fact.modelData.copy !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: if (fact.modelData.copy !== "")
                        root.panel.hostWidget.copyText(fact.modelData.copy)
                }
                Label {
                    id: factLabel
                    anchors.left: parent.left
                    anchors.leftMargin: root.panel.gaps.lg
                    anchors.top: parent.top
                    anchors.topMargin: root.panel.gaps.sm
                    width: Style.space(132)
                    text: fact.modelData.label
                    color: root.panel.dim
                    elide: Text.ElideRight
                }
                Label {
                    id: factValue
                    anchors.left: factLabel.right
                    anchors.right: copyHint.left
                    anchors.rightMargin: root.panel.gaps.md
                    anchors.top: parent.top
                    anchors.topMargin: root.panel.gaps.sm
                    text: fact.modelData.value
                    wrapMode: Text.WrapAnywhere
                }
                Label {
                    id: copyHint
                    anchors.right: parent.right
                    anchors.rightMargin: root.panel.gaps.lg
                    anchors.verticalCenter: parent.verticalCenter
                    // nf-md-content_copy
                    text: "\u{f018f}"
                    color: root.panel.dim
                    opacity: fact.hasCursor ? 1 : 0
                }
            }
        }
    }

    Flow {
        width: parent.width
        visible: root.panel.view === "detail"
        spacing: root.panel.gaps.md
        Ui.Button {
            visible: !!root.panel.selectedRow.url
            text: "Open in browser"
            // nf-md-open_in_new
            iconText: "\u{f03cc}"
            bordered: true
            selected: true
            foreground: root.panel.foreground
            onClicked: root.panel.openCurrent("")
        }
        Ui.Button {
            visible: root.panel.canOpenAs
            text: "Open as HTTP"
            bordered: true
            foreground: root.panel.foreground
            onClicked: root.panel.openCurrent("http")
        }
        Ui.Button {
            visible: root.panel.canOpenAs
            text: "Open as HTTPS"
            bordered: true
            foreground: root.panel.foreground
            onClicked: root.panel.openCurrent("https")
        }
        Ui.Button {
            visible: !!root.panel.selectedRow.copyText
            text: root.panel.selectedRow.url ? "Copy URL" : root.panel.selectedRow.kind === "port" ? "Copy address" : "Copy name"
            iconText: "\u{f018f}"
            bordered: true
            foreground: root.panel.foreground
            onClicked: root.panel.copyCurrent()
        }
        Ui.Button {
            visible: !!root.panel.selectedRow.containerId && root.panel.cfg.dockerEnabled
            text: "View logs"
            // nf-md-text_box_outline
            iconText: "\u{f09ed}"
            bordered: true
            foreground: root.panel.foreground
            onClicked: root.panel.showLogs()
        }
    }

    Flow {
        width: parent.width
        visible: root.panel.view === "detail"
        spacing: root.panel.gaps.md
        Repeater {
            model: Model.availableActions(root.panel.selectedRow, root.panel.cfg, root.panel.inventory)
            Ui.Button {
                required property var modelData
                text: modelData.label + (modelData.key ? " (" + modelData.key + ")" : "")
                bordered: true
                foreground: modelData.destructive ? root.panel.urgent : root.panel.foreground
                enabled: !root.panel.operating
                onClicked: root.panel.requestAction(modelData, root.panel.selectedRow)
            }
        }
    }
    Column {
        width: parent.width
        visible: root.panel.view === "detail" && root.panel.selectedRow.kind === "project"
        spacing: root.panel.gaps.md
        Label {
            text: "Services"
            color: root.panel.dim
        }
        Repeater {
            model: root.panel.selectedRow.kind === "project" ? Model.projectServices(root.panel.inventory, root.panel.selectedRow.projectPath, root.panel.cfg) : []
            Ui.Button {
                required property var modelData
                width: parent.width
                text: (modelData.lead ? ":" + modelData.lead + " · " : "") + modelData.title + " · " + modelData.badge
                bordered: true
                foreground: root.panel.foreground
                onClicked: {
                    root.panel.selectTab(modelData.kind === "container" ? "Docker" : "Localhost");
                    var index = root.panel.visibleRows.findIndex(function (row) {
                        return row.id === modelData.id;
                    });
                    root.panel.openDetail(index);
                }
            }
        }
    }
    Flickable {
        id: logFlick
        width: parent.width
        height: Style.space(360)
        visible: root.panel.view === "logs"
        contentWidth: width
        contentHeight: logText.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        QQC.ScrollBar.vertical: QQC.ScrollBar {
            policy: QQC.ScrollBar.AsNeeded
        }
        // New output lands at the bottom, where the newest lines are.
        onContentHeightChanged: contentY = Math.max(0, contentHeight - height)
        TextEdit {
            id: logText
            readonly property var logs: root.panel.hostWidget ? root.panel.hostWidget.logs : null
            width: logFlick.width - root.panel.gaps.lg
            readOnly: true
            selectByMouse: true
            textFormat: TextEdit.PlainText
            wrapMode: TextEdit.WrapAnywhere
            color: logs && logs.failed ? root.panel.urgent : logs && logs.loading ? root.panel.dim : root.panel.foreground
            selectionColor: Style.selectionFillFor(root.panel.foreground, root.panel.accent)
            selectedTextColor: root.panel.foreground
            font.family: root.panel.fontFamily
            font.pixelSize: root.panel.fonts.bodySmall
            text: !logs ? "" : logs.loading ? "Loading…" : logs.text !== "" ? logs.text : "No log output."
        }
    }

    RowLayout {
        width: parent.width
        visible: root.panel.view === "logs"
        spacing: root.panel.gaps.lg
        Label {
            Layout.fillWidth: true
            text: "Logs can contain secrets. Nothing is saved to disk."
            color: root.panel.dim
            font.pixelSize: root.panel.fonts.caption
            wrapMode: Text.WordWrap
        }
        Ui.Button {
            text: "Reload"
            iconText: "\u{f0450}"
            bordered: true
            foreground: root.panel.foreground
            onClicked: root.panel.showLogs()
        }
    }
}
