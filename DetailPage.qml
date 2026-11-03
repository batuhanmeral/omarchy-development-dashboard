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
    readonly property var strings: panel.translations
    readonly property alias logSearchField: logSearch
    readonly property var logs: panel.hostWidget ? panel.hostWidget.logs : null
    readonly property var filteredLog: Model.filterLog(logs && !logs.failed ? logs.text : "", panel.logQuery)
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
            tooltipText: root.panel.view === "logs" ? root.strings.t("detail.backToDetails") : root.strings.t("detail.back")
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
                text: root.panel.view === "logs" ? root.strings.tn("logs.recent", 100).arg(100) : root.panel.selectedRow.subtitle || ""
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

    Label {
        objectName: "systemDatabaseHint"
        width: parent.width
        visible: root.panel.view === "detail" && Model.isSystemDatabase(root.panel.selectedRow)
        text: root.strings.t("detail.systemDatabase")
        wrapMode: Text.WordWrap
        color: root.panel.dim
    }

    Flow {
        width: parent.width
        visible: root.panel.view === "detail"
        spacing: root.panel.gaps.md
        Ui.Button {
            visible: !!root.panel.selectedRow.url
            text: root.strings.t("detail.openBrowser")
            // nf-md-open_in_new
            iconText: "\u{f03cc}"
            bordered: true
            selected: true
            foreground: root.panel.foreground
            onClicked: root.panel.openCurrent("")
        }
        Ui.Button {
            visible: root.panel.canOpenAs
            text: root.strings.t("detail.openHttp")
            bordered: true
            foreground: root.panel.foreground
            onClicked: root.panel.openCurrent("http")
        }
        Ui.Button {
            visible: root.panel.canOpenAs
            text: root.strings.t("detail.openHttps")
            bordered: true
            foreground: root.panel.foreground
            onClicked: root.panel.openCurrent("https")
        }
        Ui.Button {
            // Projects copy their path through their own action button.
            visible: !!root.panel.selectedRow.copyText && root.panel.selectedRow.kind !== "project"
            text: root.panel.selectedRow.url ? root.strings.t("detail.copyUrl") : root.panel.selectedRow.kind === "port" ? root.strings.t("detail.copyAddress") : root.strings.t("detail.copyName")
            iconText: "\u{f018f}"
            bordered: true
            foreground: root.panel.foreground
            onClicked: root.panel.copyCurrent()
        }
        Ui.Button {
            visible: !!root.panel.selectedRow.containerId && root.panel.cfg.dockerEnabled
            text: root.strings.t("detail.viewLogs")
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
            model: Model.availableActions(root.panel.selectedRow, root.panel.cfg, root.panel.inventory, root.strings)
            Ui.Button {
                required property var modelData
                objectName: "detailAction-" + modelData.id
                text: modelData.label + (modelData.key ? " (" + modelData.key + ")" : "")
                bordered: true
                foreground: modelData.destructive ? root.panel.urgent : root.panel.foreground
                enabled: !root.panel.operating
                onClicked: root.panel.requestAction(modelData, root.panel.selectedRow)
            }
        }
    }
    Column {
        id: serviceList
        readonly property var services: root.panel.selectedRow.kind === "project" ? Model.projectServices(root.panel.inventory, root.panel.selectedRow.projectPath, root.panel.cfg, null, root.strings) : root.panel.selectedRow.kind === "compose" ? Model.composeMembers(root.panel.inventory, root.panel.selectedRow.title, root.panel.cfg, root.strings) : []
        width: parent.width
        visible: root.panel.view === "detail" && services.length > 0
        spacing: root.panel.gaps.md
        Label {
            text: root.panel.selectedRow.kind === "compose" ? root.strings.t("detail.containers") : root.strings.t("fact.services")
            color: root.panel.dim
        }
        Repeater {
            model: serviceList.services
            Ui.Button {
                required property var modelData
                objectName: root.panel.selectedRow.kind === "compose" ? "composeMember" : "projectService"
                width: parent.width
                text: (modelData.lead ? ":" + modelData.lead + " · " : "") + modelData.title + " · " + modelData.badge
                bordered: true
                foreground: root.panel.foreground
                onClicked: root.panel.openRelated(modelData)
            }
        }
    }
    RowLayout {
        width: parent.width
        visible: root.panel.view === "logs"
        spacing: root.panel.gaps.md
        Ui.TextField {
            id: logSearch
            objectName: "logSearch"
            Layout.fillWidth: true
            placeholderText: root.strings.t("logs.search")
            foreground: root.panel.foreground
            onTextEdited: root.panel.logQuery = text
            Keys.onEscapePressed: {
                root.panel.logQuery = "";
                root.panel.focusKeys();
            }
            Keys.onReturnPressed: root.panel.focusKeys()
            Keys.onEnterPressed: root.panel.focusKeys()
            Connections {
                target: root.panel
                function onLogQueryChanged() {
                    if (logSearch.text !== root.panel.logQuery)
                        logSearch.text = root.panel.logQuery;
                }
            }
        }
        Label {
            objectName: "logMatchCount"
            visible: root.panel.logQuery !== "" && !!root.logs && !root.logs.failed
            text: root.strings.tn("logs.matches", root.filteredLog.total).arg(root.filteredLog.matched).arg(root.filteredLog.total)
            color: root.panel.dim
            font.pixelSize: root.panel.fonts.caption
        }
        Ui.Button {
            text: root.strings.t("logs.follow")
            tooltipText: root.strings.t("logs.followTooltip")
            bordered: true
            selected: root.panel.logFollow
            foreground: root.panel.foreground
            onClicked: root.panel.logFollow = !root.panel.logFollow
        }
    }

    Flickable {
        id: logFlick
        objectName: "logScroll"
        property bool awaitingInitialLog: true
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
        function scrollToEnd() {
            if (root.panel.view === "logs" && root.panel.logFollow)
                contentY = Math.max(0, contentHeight - height);
        }
        function settleLog() {
            if (root.panel.view !== "logs" || !root.logs || root.logs.loading || !root.logs.containerId)
                return;
            if (awaitingInitialLog) {
                awaitingInitialLog = false;
                contentY = Math.max(0, contentHeight - height);
            } else {
                scrollToEnd();
            }
        }
        onContentHeightChanged: scrollToEnd()
        onVisibleChanged: {
            if (!visible) {
                awaitingInitialLog = true;
                contentY = 0;
            }
        }
        Connections {
            target: root.logs
            function onLoadingChanged() {
                if (!root.logs.loading)
                    Qt.callLater(logFlick.settleLog);
            }
        }
        Connections {
            target: root.panel
            function onLogFollowChanged() {
                logFlick.scrollToEnd();
            }
        }
        TextEdit {
            id: logText
            objectName: "logText"
            width: logFlick.width - root.panel.gaps.lg
            readOnly: true
            selectByMouse: true
            textFormat: TextEdit.PlainText
            wrapMode: TextEdit.WrapAnywhere
            color: root.logs && root.logs.failed ? root.panel.urgent : root.logs && root.logs.loading && !root.logs.text ? root.panel.dim : root.panel.foreground
            selectionColor: Style.selectionFillFor(root.panel.foreground, root.panel.accent)
            selectedTextColor: root.panel.foreground
            font.family: root.panel.fontFamily
            font.pixelSize: root.panel.fonts.bodySmall
            onTextChanged: Qt.callLater(logFlick.scrollToEnd)
            text: {
                if (!root.logs)
                    return "";
                if (root.logs.failed)
                    return root.logs.text;
                if (root.logs.loading && !root.logs.text)
                    return root.strings.t("common.loading");
                if (!root.panel.logQuery && root.logs.truncated)
                    return root.filteredLog.text.replace(/\n$/, "") + "\n" + root.strings.t("logs.truncated");
                return root.filteredLog.text || (root.panel.logQuery ? root.strings.t("logs.noMatches") : root.strings.t("logs.empty"));
            }
        }
    }

    RowLayout {
        width: parent.width
        visible: root.panel.view === "logs"
        spacing: root.panel.gaps.lg
        Label {
            Layout.fillWidth: true
            text: root.strings.t("logs.privacy")
            color: root.panel.dim
            font.pixelSize: root.panel.fonts.caption
            wrapMode: Text.WordWrap
        }
        Ui.Button {
            text: root.strings.t("logs.reload")
            iconText: "\u{f0450}"
            bordered: true
            foreground: root.panel.foreground
            onClicked: root.panel.showLogs()
        }
    }
}
