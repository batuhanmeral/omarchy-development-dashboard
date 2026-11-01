pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui
import "Model.js" as Model

// The popup. It holds view state only; data, polling and actions live in BarWidget.qml and
// arrive through `hostWidget`.
Ui.Panel {
    id: root
    moduleName: "io.github.batuhanmeral.devports"
    ipcTarget: "io.github.batuhanmeral.devports"

    readonly property var hostBar: bar
    property Item anchorItem: null
    property var hostWidget: null

    property string tab: "Localhost"
    property string query: ""
    property string filter: "all"
    // "list", "detail", "logs" or "settings".
    property string view: "list"
    property int cursor: 0
    property string selectedId: ""
    property var selectedRow: ({})
    property double now: Date.now() / 1000

    // Style and Color expose their token groups as plain QtObjects; `var` aliases keep qmllint quiet.
    readonly property var fonts: Style.font
    readonly property var gaps: Style.spacing
    readonly property var popupColors: Commons.Color.popups
    readonly property color foreground: popupColors.text
    readonly property color dim: Qt.darker(foreground, 1.4)
    readonly property color urgent: Commons.Color.urgent
    // red/green/yellow/blue from the active theme; see Model.palette.
    property var statusColors: Model.palette("")
    readonly property color accent: Commons.Color.accent
    readonly property string fontFamily: fonts.family

    readonly property var cfg: hostWidget ? hostWidget.cfg : Model.config({})
    readonly property var inventory: hostWidget ? hostWidget.inventory : ({})
    readonly property var errors: hostWidget ? hostWidget.errors : ({})
    readonly property var counts: hostWidget ? hostWidget.counts : ({})
    readonly property bool sampled: hostWidget ? hostWidget.lastUpdate > 0 || hostWidget.hasError : false
    readonly property var visibleRows: Model.rows(inventory, tab, query, filter, cfg)
    readonly property string dockerNotice: Model.dockerNotice(inventory, errors, cfg)
    readonly property var selectedFacts: selectedId ? Model.facts(selectedRow, now) : []
    readonly property string updatedText: hostWidget && hostWidget.lastUpdate > 0 ? "Updated " + new Date(hostWidget.lastUpdate).toLocaleTimeString(Qt.locale(Commons.I18n.formatLocale), Locale.ShortFormat) + " · " : ""
    readonly property bool canOpenAs: selectedRow.kind === "port" && !selectedRow.url && selectedRawRow.database === null
    readonly property var selectedRawRow: {
        try {
            return JSON.parse(selectedRow.raw || "{}");
        } catch (error) {
            return {};
        }
    }

    // Themes may set accent to any hue, so tone never relies on it: plain, dimmed or urgent.
    function toneColor(tone) {
        return tone === "urgent" ? statusColors.red : tone === "warn" ? statusColors.yellow : tone === "ok" ? statusColors.green : tone === "info" ? statusColors.blue : dim;
    }

    function switchPanel(direction) {
        return root.bar && typeof root.hostBar.switchPanelFrom === "function" ? root.hostBar.switchPanelFrom(root.hostWidget || root, direction) : false;
    }

    function moveCursor(delta) {
        cursor = Math.max(0, Math.min(listModel.count - 1, cursor + delta));
    }

    function openDetail(index) {
        if (index < 0 || index >= visibleRows.length)
            return;
        cursor = index;
        selectedRow = visibleRows[index];
        selectedId = selectedRow.id;
        now = Date.now() / 1000;
        view = "detail";
    }

    function showLogs() {
        if (!hostWidget || !selectedRow.containerId)
            return;
        view = "logs";
        hostWidget.requestLogs(selectedRow.containerId);
    }

    // One step towards the list: logs -> detail -> list, settings -> list.
    function back() {
        if (hostWidget)
            hostWidget.clearLogs();
        if (view === "logs") {
            view = "detail";
            return;
        }
        selectedId = "";
        selectedRow = {};
        view = "list";
    }

    function toggleSettings() {
        var leaving = view === "settings";
        if (view === "logs")
            back();
        back();
        if (!leaving)
            view = "settings";
    }

    function selectTab(name) {
        if (cfg.tabs.indexOf(name) < 0)
            return;
        back();
        view = "list";
        tab = name;
        filter = "all";
        query = "";
        cursor = 0;
    }

    function stepTab(direction) {
        var index = cfg.tabs.indexOf(tab) + direction;
        if (index >= 0 && index < cfg.tabs.length)
            selectTab(cfg.tabs[index]);
    }

    function copyCurrent() {
        var row = view === "list" ? visibleRows[cursor] : selectedRow;
        if (hostWidget && row && row.copyText)
            hostWidget.copyText(row.copyText);
    }

    function openCurrent(scheme) {
        if (hostWidget && selectedRow.kind === "port")
            hostWidget.openUrl(selectedRawRow, scheme);
    }

    onCfgChanged: {
        if (cfg.tabs.indexOf(tab) < 0)
            selectTab(cfg.tabs[0]);
    }
    onVisibleRowsChanged: {
        Model.sync(listModel, visibleRows);
        cursor = Math.max(0, Math.min(visibleRows.length - 1, cursor));
        if (!selectedId)
            return;
        let match = visibleRows.filter(function (row) {
            return row.id === root.selectedId;
        });
        if (match.length) {
            selectedRow = match[0];
        } else {
            // The service went away while its details were open.
            if (view === "logs")
                back();
            back();
        }
    }
    onOpenedChanged: {
        if (opened)
            now = Date.now() / 1000;
        else if (view === "logs" || view === "settings")
            back();
    }

    ListModel {
        id: listModel
    }

    FileView {
        id: themeColors
        path: Commons.Color.currentThemePath + "/colors.toml"
        printErrors: false
        onLoaded: root.statusColors = Model.palette(text())
        onLoadFailed: root.statusColors = Model.palette("")
    }
    // A theme switch reloads Commons.Color; read the new palette with it.
    Connections {
        target: Commons.Color
        function onBackgroundChanged() {
            themeColors.reload();
        }
        function onAccentChanged() {
            themeColors.reload();
        }
    }

    Timer {
        interval: 30000
        repeat: true
        running: root.opened && root.view === "detail"
        onTriggered: root.now = Date.now() / 1000
    }

    component Label: Text {
        textFormat: Text.PlainText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: root.fonts.body
    }

    component Badge: Ui.BorderSurface {
        id: badge
        property string text: ""
        property color tint: root.dim
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
            font.pixelSize: root.fonts.caption
            font.bold: true
        }
    }

    Ui.KeyboardPanel {
        id: surface
        anchorItem: root.anchorItem
        owner: root.hostWidget || root
        bar: root.bar
        open: root.opened
        focusTarget: surface.loadedContent
        contentWidth: surface.fittedContentWidth(Style.space(460))
        contentHeight: surface.fittedContentHeight(surface.loadedContentHeight, Style.space(800))

        content: Component {
            Ui.PanelKeyCatcher {
                id: keys
                objectName: "keys"
                implicitHeight: column.implicitHeight
                blocked: search.activeFocus || settingsForm.editing

                // A view change hides whatever input had focus; keys belong to the panel again.
                Connections {
                    target: root
                    function onViewChanged() {
                        keys.forceActiveFocus();
                    }
                }

                onCloseRequested: {
                    if (root.view !== "list")
                        root.back();
                    else if (root.query !== "")
                        root.query = "";
                    else
                        root.close();
                }
                onTabRequested: function (direction) {
                    root.switchPanel(direction);
                }
                onMoveRequested: function (dx, dy) {
                    if (root.view === "list" && dy !== 0) {
                        root.moveCursor(dy);
                        list.positionViewAtIndex(root.cursor, ListView.Contain);
                    } else if (root.view === "list") {
                        root.stepTab(dx);
                    } else if (dx < 0 && root.view !== "settings") {
                        root.back();
                    } else if (dx > 0 && root.view === "detail" && root.cfg.dockerEnabled) {
                        root.showLogs();
                    }
                }
                onActivateRequested: {
                    if (root.view === "list")
                        root.openDetail(root.cursor);
                }
                onTextKey: function (key, modifiers) {
                    if (modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier) || root.view === "settings")
                        return;
                    if (key === "r")
                        root.hostWidget.refresh();
                    else if (key === "c")
                        root.copyCurrent();
                    else if (key === "/" && root.view === "list")
                        search.forceActiveFocus();
                    else if (key === "o" && root.view === "detail" && root.selectedRow.url)
                        root.openCurrent("");
                    else if (key === "s")
                        root.toggleSettings();
                    else if (key >= "1" && key <= "4")
                        root.selectTab(root.cfg.tabs[Number(key) - 1] || "");
                }

                Flickable {
                    id: flick
                    anchors.fill: parent
                    contentWidth: width
                    contentHeight: column.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    flickableDirection: Flickable.VerticalFlick
                    interactive: contentHeight > height
                    QQC.ScrollBar.vertical: QQC.ScrollBar {
                        policy: QQC.ScrollBar.AsNeeded
                    }

                    Column {
                        id: column
                        width: flick.width
                        spacing: root.gaps.xxl

                        // Header: what this is, a one-line summary, refresh and settings.
                        Item {
                            width: parent.width
                            implicitHeight: Math.max(titles.implicitHeight, headerActions.implicitHeight)
                            // The widget's glyph, as tall as the title and summary lines together.
                            Text {
                                id: headerIcon
                                anchors.left: parent.left
                                anchors.verticalCenter: titles.verticalCenter
                                width: titles.implicitHeight
                                height: titles.implicitHeight
                                textFormat: Text.PlainText
                                text: Model.icon
                                color: root.foreground
                                font.family: root.fontFamily
                                font.pixelSize: titles.implicitHeight
                                fontSizeMode: Text.Fit
                                minimumPixelSize: root.fonts.body
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                            }
                            Column {
                                id: titles
                                anchors.left: headerIcon.right
                                anchors.leftMargin: root.gaps.lg
                                anchors.right: headerActions.left
                                anchors.rightMargin: root.gaps.lg
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: Style.space(2)
                                Label {
                                    width: parent.width
                                    text: root.view === "settings" ? "Development Ports settings" : "Development Ports"
                                    font.pixelSize: root.fonts.title
                                    font.bold: true
                                    elide: Text.ElideRight
                                }
                                Label {
                                    width: parent.width
                                    text: Model.summary(root.inventory, root.cfg).toUpperCase()
                                    color: root.dim
                                    font.pixelSize: root.fonts.caption
                                    font.bold: true
                                    font.letterSpacing: 1.2
                                    elide: Text.ElideRight
                                }
                            }
                            Row {
                                id: headerActions
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: root.gaps.sm
                                Ui.Button {
                                    // nf-md-refresh
                                    iconText: "\u{f0450}"
                                    iconSpinning: !!root.hostWidget && root.hostWidget.refreshing
                                    tooltipText: "Refresh (r)"
                                    foreground: root.foreground
                                    horizontalPadding: root.gaps.md
                                    onClicked: root.hostWidget.refresh()
                                }
                                Ui.Button {
                                    // nf-md-cog
                                    iconText: "\u{f0493}"
                                    tooltipText: "Settings (s)"
                                    selected: root.view === "settings"
                                    foreground: root.foreground
                                    horizontalPadding: root.gaps.md
                                    onClicked: root.toggleSettings()
                                }
                            }
                        }

                        // A failed port query: the one condition that also turns the bar icon urgent.
                        Ui.BorderSurface {
                            width: parent.width
                            visible: !!root.hostWidget && root.hostWidget.hasError
                            implicitHeight: errorLabel.implicitHeight + root.gaps.lg * 2
                            radius: Style.cornerRadius
                            color: Util.alpha(root.urgent, 0.12)
                            border.width: 1
                            border.color: Util.alpha(root.urgent, 0.5)
                            Label {
                                id: errorLabel
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.margins: root.gaps.xl
                                text: (root.hostWidget ? root.hostWidget.errorText : "") + "\nShowing the last successful sample."
                                color: root.urgent
                                font.pixelSize: root.fonts.bodySmall
                                wrapMode: Text.WordWrap
                                maximumLineCount: 4
                                elide: Text.ElideRight
                            }
                        }

                        // ---- list ---------------------------------------------------------
                        Column {
                            width: parent.width
                            visible: root.view === "list"
                            spacing: root.gaps.lg

                            Row {
                                id: tabRow
                                width: parent.width
                                spacing: root.gaps.sm
                                visible: root.cfg.tabs.length > 1
                                Repeater {
                                    model: root.cfg.tabs
                                    Ui.Button {
                                        required property string modelData
                                        width: (tabRow.width - tabRow.spacing * (root.cfg.tabs.length - 1)) / root.cfg.tabs.length
                                        text: Model.tabLabel(modelData) + (root.sampled ? " " + (root.counts[modelData] || 0) : "")
                                        selected: root.tab === modelData
                                        bordered: true
                                        foreground: root.foreground
                                        onClicked: root.selectTab(modelData)
                                    }
                                }
                            }

                            Item {
                                width: parent.width
                                implicitHeight: Math.max(search.implicitHeight, filterGroup.implicitHeight)
                                Ui.TextField {
                                    id: search
                                    objectName: "search"
                                    anchors.left: parent.left
                                    anchors.right: filterGroup.left
                                    anchors.rightMargin: root.gaps.lg
                                    anchors.verticalCenter: parent.verticalCenter
                                    placeholderText: "Search  ( / )"
                                    foreground: root.foreground
                                    // Typing breaks a plain binding, so follow resets explicitly.
                                    Connections {
                                        target: root
                                        function onQueryChanged() {
                                            if (search.text !== root.query)
                                                search.text = root.query;
                                        }
                                    }
                                    onTextEdited: {
                                        root.query = text;
                                        root.cursor = 0;
                                    }
                                    Keys.onEscapePressed: {
                                        if (text !== "")
                                            root.query = "";
                                        else
                                            keys.forceActiveFocus();
                                    }
                                    Keys.onReturnPressed: keys.forceActiveFocus()
                                    Keys.onEnterPressed: keys.forceActiveFocus()
                                    Keys.onDownPressed: keys.forceActiveFocus()
                                }
                                Ui.ButtonGroup {
                                    id: filterGroup
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: root.gaps.sm
                                    focusable: false
                                    options: Model.filters(root.tab)
                                    value: root.filter
                                    foreground: root.foreground
                                    fontSize: root.fonts.bodySmall
                                    onChanged: function (value) {
                                        root.filter = value;
                                        root.cursor = 0;
                                    }
                                }
                            }

                            // A Docker problem that still leaves rows to show, e.g. missing CPU figures.
                            Label {
                                width: parent.width
                                visible: root.tab !== "Localhost" && root.dockerNotice !== "" && listModel.count > 0
                                text: root.dockerNotice
                                color: root.dim
                                font.pixelSize: root.fonts.bodySmall
                                wrapMode: Text.WordWrap
                                maximumLineCount: 2
                                elide: Text.ElideRight
                            }

                            ListView {
                                id: list
                                width: parent.width
                                height: Math.min(contentHeight, Style.space(376))
                                visible: listModel.count > 0
                                clip: true
                                model: listModel
                                spacing: Style.space(2)
                                reuseItems: true
                                boundsBehavior: Flickable.StopAtBounds
                                flickableDirection: Flickable.VerticalFlick
                                interactive: contentHeight > height
                                QQC.ScrollBar.vertical: QQC.ScrollBar {
                                    policy: QQC.ScrollBar.AsNeeded
                                }

                                delegate: Ui.CursorSurface {
                                    id: rowItem
                                    required property int index
                                    required property string lead
                                    required property string title
                                    required property string subtitle
                                    required property string badge
                                    required property string tone
                                    required property string copyText
                                    width: list.width
                                    implicitHeight: Style.space(root.cfg.compact ? 40 : 50)
                                    hasCursor: root.cursor === index
                                    foreground: root.foreground

                                    MouseArea {
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onContainsMouseChanged: if (containsMouse)
                                            root.cursor = rowItem.index
                                        onClicked: root.openDetail(rowItem.index)
                                    }

                                    RowLayout {
                                        anchors.fill: parent
                                        anchors.leftMargin: root.gaps.xl
                                        anchors.rightMargin: root.gaps.lg
                                        spacing: root.gaps.xl

                                        // Port number, or a state dot for rows that have none.
                                        Item {
                                            Layout.preferredWidth: rowItem.lead !== "" ? leadMetrics.advanceWidth : Style.space(7)
                                            Layout.fillHeight: true
                                            Label {
                                                anchors.right: parent.right
                                                anchors.verticalCenter: parent.verticalCenter
                                                visible: rowItem.lead !== ""
                                                text: rowItem.lead
                                                font.bold: true
                                            }
                                            Rectangle {
                                                anchors.centerIn: parent
                                                visible: rowItem.lead === ""
                                                width: Style.space(7)
                                                height: width
                                                radius: width / 2
                                                color: root.toneColor(rowItem.tone)
                                            }
                                        }
                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            Layout.minimumWidth: 0
                                            spacing: Style.space(1)
                                            Label {
                                                Layout.fillWidth: true
                                                text: rowItem.title
                                                elide: Text.ElideMiddle
                                            }
                                            Label {
                                                Layout.fillWidth: true
                                                text: rowItem.subtitle
                                                color: root.dim
                                                font.pixelSize: root.fonts.caption
                                                elide: Text.ElideRight
                                            }
                                        }
                                        Badge {
                                            text: rowItem.badge
                                            tint: root.toneColor(rowItem.tone)
                                        }
                                        Ui.PanelActionButton {
                                            // nf-md-content_copy
                                            iconText: "\u{f018f}"
                                            tooltipText: "Copy " + rowItem.copyText
                                            foreground: root.foreground
                                            opacity: rowItem.hasCursor ? 1 : 0
                                            enabled: rowItem.hasCursor && rowItem.copyText !== ""
                                            onClicked: root.hostWidget.copyText(rowItem.copyText)
                                        }
                                    }
                                }
                            }

                            Item {
                                width: parent.width
                                visible: listModel.count === 0
                                implicitHeight: Style.space(132)
                                Label {
                                    anchors.centerIn: parent
                                    width: parent.width - Style.space(48)
                                    horizontalAlignment: Text.AlignHCenter
                                    wrapMode: Text.WordWrap
                                    color: root.dim
                                    text: Model.emptyText(root.tab, root.query, root.filter, root.dockerNotice, root.sampled)
                                }
                            }
                        }

                        // ---- detail and logs ----------------------------------------------
                        Column {
                            width: parent.width
                            visible: root.view === "detail" || root.view === "logs"
                            spacing: root.gaps.xl

                            RowLayout {
                                width: parent.width
                                spacing: root.gaps.lg
                                Ui.PanelActionButton {
                                    // nf-md-arrow_left
                                    iconText: "\u{f004d}"
                                    tooltipText: root.view === "logs" ? "Back to details (Esc)" : "Back to the list (Esc)"
                                    foreground: root.foreground
                                    bordered: true
                                    Layout.alignment: Qt.AlignVCenter
                                    onClicked: root.back()
                                }
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    Layout.minimumWidth: 0
                                    spacing: Style.space(1)
                                    Label {
                                        Layout.fillWidth: true
                                        text: (root.selectedRow.lead ? ":" + root.selectedRow.lead + "  " : "") + (root.selectedRow.title || "")
                                        font.pixelSize: root.fonts.subtitle
                                        font.bold: true
                                        elide: Text.ElideMiddle
                                    }
                                    Label {
                                        Layout.fillWidth: true
                                        text: root.view === "logs" ? "Last 100 log lines" : root.selectedRow.subtitle || ""
                                        color: root.dim
                                        font.pixelSize: root.fonts.caption
                                        elide: Text.ElideRight
                                    }
                                }
                                Badge {
                                    Layout.alignment: Qt.AlignVCenter
                                    text: root.selectedRow.badge || ""
                                    tint: root.toneColor(root.selectedRow.tone || "dim")
                                }
                            }

                            Ui.PanelSeparator {
                                foreground: root.foreground
                            }

                            // Facts: click a value to copy it.
                            Column {
                                width: parent.width
                                visible: root.view === "detail"
                                spacing: Style.space(2)
                                Repeater {
                                    model: root.selectedFacts
                                    Ui.CursorSurface {
                                        id: fact
                                        required property var modelData
                                        width: parent.width
                                        implicitHeight: Math.max(factValue.implicitHeight, factLabel.implicitHeight) + root.gaps.lg
                                        hasCursor: factMouse.containsMouse && fact.modelData.copy !== ""
                                        foreground: root.foreground
                                        MouseArea {
                                            id: factMouse
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: fact.modelData.copy !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor
                                            onClicked: if (fact.modelData.copy !== "")
                                                root.hostWidget.copyText(fact.modelData.copy)
                                        }
                                        Label {
                                            id: factLabel
                                            anchors.left: parent.left
                                            anchors.leftMargin: root.gaps.lg
                                            anchors.top: parent.top
                                            anchors.topMargin: root.gaps.sm
                                            width: Style.space(132)
                                            text: fact.modelData.label
                                            color: root.dim
                                            elide: Text.ElideRight
                                        }
                                        Label {
                                            id: factValue
                                            anchors.left: factLabel.right
                                            anchors.right: copyHint.left
                                            anchors.rightMargin: root.gaps.md
                                            anchors.top: parent.top
                                            anchors.topMargin: root.gaps.sm
                                            text: fact.modelData.value
                                            wrapMode: Text.WrapAnywhere
                                        }
                                        Label {
                                            id: copyHint
                                            anchors.right: parent.right
                                            anchors.rightMargin: root.gaps.lg
                                            anchors.verticalCenter: parent.verticalCenter
                                            // nf-md-content_copy
                                            text: "\u{f018f}"
                                            color: root.dim
                                            opacity: fact.hasCursor ? 1 : 0
                                        }
                                    }
                                }
                            }

                            Flow {
                                width: parent.width
                                visible: root.view === "detail"
                                spacing: root.gaps.md
                                Ui.Button {
                                    visible: !!root.selectedRow.url
                                    text: "Open in browser"
                                    // nf-md-open_in_new
                                    iconText: "\u{f03cc}"
                                    bordered: true
                                    selected: true
                                    foreground: root.foreground
                                    onClicked: root.openCurrent("")
                                }
                                Ui.Button {
                                    visible: root.canOpenAs
                                    text: "Open as HTTP"
                                    bordered: true
                                    foreground: root.foreground
                                    onClicked: root.openCurrent("http")
                                }
                                Ui.Button {
                                    visible: root.canOpenAs
                                    text: "Open as HTTPS"
                                    bordered: true
                                    foreground: root.foreground
                                    onClicked: root.openCurrent("https")
                                }
                                Ui.Button {
                                    visible: !!root.selectedRow.copyText
                                    text: root.selectedRow.url ? "Copy URL" : root.selectedRow.kind === "port" ? "Copy address" : "Copy name"
                                    iconText: "\u{f018f}"
                                    bordered: true
                                    foreground: root.foreground
                                    onClicked: root.copyCurrent()
                                }
                                Ui.Button {
                                    visible: !!root.selectedRow.containerId && root.cfg.dockerEnabled
                                    text: "View logs"
                                    // nf-md-text_box_outline
                                    iconText: "\u{f09ed}"
                                    bordered: true
                                    foreground: root.foreground
                                    onClicked: root.showLogs()
                                }
                            }

                            Flickable {
                                id: logFlick
                                width: parent.width
                                height: Style.space(360)
                                visible: root.view === "logs"
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
                                    readonly property var logs: root.hostWidget ? root.hostWidget.logs : null
                                    width: logFlick.width - root.gaps.lg
                                    readOnly: true
                                    selectByMouse: true
                                    textFormat: TextEdit.PlainText
                                    wrapMode: TextEdit.WrapAnywhere
                                    color: logs && logs.failed ? root.urgent : logs && logs.loading ? root.dim : root.foreground
                                    selectionColor: Style.selectionFillFor(root.foreground, root.accent)
                                    selectedTextColor: root.foreground
                                    font.family: root.fontFamily
                                    font.pixelSize: root.fonts.bodySmall
                                    text: !logs ? "" : logs.loading ? "Loading…" : logs.text !== "" ? logs.text : "No log output."
                                }
                            }

                            RowLayout {
                                width: parent.width
                                visible: root.view === "logs"
                                spacing: root.gaps.lg
                                Label {
                                    Layout.fillWidth: true
                                    text: "Logs can contain secrets. Nothing is saved to disk."
                                    color: root.dim
                                    font.pixelSize: root.fonts.caption
                                    wrapMode: Text.WordWrap
                                }
                                Ui.Button {
                                    text: "Reload"
                                    iconText: "\u{f0450}"
                                    bordered: true
                                    foreground: root.foreground
                                    onClicked: root.showLogs()
                                }
                            }
                        }

                        // ---- settings -----------------------------------------------------
                        Settings {
                            id: settingsForm
                            objectName: "settings"
                            width: parent.width
                            visible: root.view === "settings"
                            onVisibleChanged: if (visible)
                                load()
                            foreground: root.foreground
                            values: root.hostWidget ? root.hostWidget.settings : ({})
                            onSaveRequested: function (values) {
                                if (root.hostWidget && root.hostWidget.saveSettings(values))
                                    root.back();
                            }
                            onCancelRequested: {
                                root.back();
                                keys.forceActiveFocus();
                            }
                        }

                        // Footer: transient feedback, otherwise how fresh the data is and the keys.
                        Label {
                            width: parent.width
                            readonly property bool hasMessage: !!root.hostWidget && root.hostWidget.message !== ""
                            text: hasMessage ? root.hostWidget.message : root.view === "list" ? root.updatedText + "↵ details · / search · c copy · s settings" : root.view === "settings" ? "Changes apply when saved · Esc cancels" : root.view === "logs" ? "Esc back to details" : "Esc back · click a value to copy it" + (root.selectedRow.containerId && root.cfg.dockerEnabled ? " · → logs" : "")
                            color: hasMessage && root.hostWidget.messageUrgent ? root.urgent : root.dim
                            font.pixelSize: root.fonts.caption
                            elide: Text.ElideRight
                            maximumLineCount: 2
                            wrapMode: Text.WordWrap
                        }
                    }
                }

                TextMetrics {
                    id: leadMetrics
                    font.family: root.fontFamily
                    font.pixelSize: root.fonts.body
                    font.bold: true
                    text: "65535"
                }
            }
        }
    }
}
