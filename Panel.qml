pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as QQC
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui
import "Model.js" as Model

// The popup. It holds view state only; data, polling and actions live in BarWidget.qml and
// arrive through `hostWidget`.
Ui.Panel {
    id: root
    moduleName: Model.pluginId
    ipcTarget: Model.pluginId

    readonly property var hostBar: bar
    property Item anchorItem: null
    property var hostWidget: null
    readonly property alias translations: strings

    property string tab: ""
    property string query: ""
    property string filter: "all"
    // "list", "detail", "logs" or "settings".
    property string view: "list"
    property bool logFollow: false
    property string logQuery: ""
    property int cursor: 0
    property string toolProject: ""
    property var confirmation: null
    readonly property bool confirming: confirmation !== null
    readonly property bool operating: !!hostWidget && hostWidget.operation.running
    readonly property var projectOptions: Model.rows(inventory, "Projects", "", "all", cfg).map(function (p) {
        return {
            value: p.projectPath,
            label: p.title + " · " + p.projectPath
        };
    })
    readonly property var entries: listModel
    property string selectedId: ""
    property string detailParentId: ""
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
    readonly property var visibleRows: Model.rows(inventory, tab, query, filter, cfg, null, strings)
    readonly property string dockerNotice: Model.dockerNotice(inventory, errors, cfg, strings)
    readonly property string scopeNotice: tab === "Projects" ? errors.projects || "" : tab === "Tools" ? errors.tools || "" : ["Docker", "Images", "Databases"].indexOf(tab) >= 0 ? dockerNotice : ""
    readonly property var selectedFacts: selectedId ? Model.facts(selectedRow, now, strings) : []
    readonly property string updatedText: hostWidget && hostWidget.lastUpdate > 0 ? strings.t("panel.updated").arg(new Date(hostWidget.lastUpdate).toLocaleTimeString(Qt.locale(Commons.I18n.formatLocale), Locale.ShortFormat)) + " · " : ""
    readonly property bool canOpenAs: selectedRow.kind === "port" && !selectedRow.url && selectedRawRow.database === null
    readonly property var selectedRawRow: {
        try {
            return JSON.parse(selectedRow.raw || "{}");
        } catch (error) {
            return {};
        }
    }

    Commons.Translations {
        id: strings
        directory: Qt.resolvedUrl("i18n")
    }

    // Themes may set accent to any hue, so tone never relies on it: plain, dimmed or urgent.
    function toneColor(tone) {
        return tone === "urgent" ? statusColors.red : tone === "warn" ? statusColors.yellow : tone === "ok" ? statusColors.green : tone === "info" ? statusColors.blue : dim;
    }

    function focusKeys() {
        if (surface.loadedContent)
            surface.loadedContent.forceActiveFocus();
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
        if (tab === "Tools") {
            launchTool(visibleRows[index]);
            return;
        }
        detailParentId = "";
        selectedRow = visibleRows[index];
        selectedId = selectedRow.id;
        now = Date.now() / 1000;
        view = "detail";
    }

    function openRelated(row) {
        const targetTab = row.kind === "container" ? "Docker" : "Localhost";
        if (selectedRow.kind === "compose" || cfg.tabs.indexOf(targetTab) < 0) {
            detailParentId = selectedId;
            selectedId = row.id;
            selectedRow = row;
            focusKeys();
            return;
        }
        selectTab(targetTab);
        const compose = row.kind === "container" ? Model.rawRow(row).compose : "";
        const id = compose ? "compose:" + compose : row.id;
        const index = visibleRows.findIndex(function (entry) {
            return entry.id === id;
        });
        openDetail(index);
        if (index >= 0 && compose)
            openRelated(row);
    }

    function detailRow(id) {
        const listRow = visibleRows.find(function (row) {
            return row.id === id;
        });
        if (listRow || !detailParentId)
            return listRow;
        const parent = visibleRows.find(function (row) {
            return row.id === root.detailParentId;
        });
        if (!parent)
            return null;
        const services = parent.kind === "project" ? Model.projectServices(inventory, parent.projectPath, cfg, null, strings) : Model.composeMembers(inventory, parent.title, cfg, strings);
        return services.find(function (row) {
            return row.id === id;
        });
    }

    function launchTool(row) {
        if (!toolProject || !projectOptions.some(function (p) {
            return p.value === root.toolProject;
        })) {
            hostWidget.notify(strings.t("panel.chooseToolProject"), true);
            return;
        }
        var raw = Model.rawRow(row);
        if (!raw.available) {
            hostWidget.notify(raw.reason || strings.t("panel.toolUnavailable"), true);
            return;
        }
        hostWidget.runOperation("launch-tool", row, {
            path: toolProject
        });
    }

    function requestAction(action, row) {
        row = row || (view === "list" ? visibleRows[cursor] : selectedRow);
        if (!row || operating || confirming)
            return;
        if (action.id === "ai") {
            toolProject = row.projectPath;
            selectTab("Tools");
            return;
        }
        if (action.id === "open") {
            hostWidget.openUrl(JSON.parse(action.raw), "http");
            return;
        }
        // Check availability again: shortcuts and stale buttons cannot bypass management settings.
        var available = Model.availableActions(row, cfg, inventory).find(function (a) {
            return a.id === action.id;
        });
        if (!available)
            return;
        if (available.confirm)
            confirmation = {
                op: action.id,
                row: row
            };
        else
            hostWidget.runOperation(action.id, row, {});
    }

    function confirmAction() {
        var pending = confirmation;
        confirmation = null;
        if (pending && hostWidget)
            hostWidget.runOperation(pending.op, pending.row, {});
    }

    function shortcut(key) {
        var row = view === "list" ? visibleRows[cursor] : selectedRow;
        if (!row || (view !== "list" && view !== "detail"))
            return;
        var action = Model.availableActions(row, cfg, inventory).filter(function (a) {
            return a.key === key;
        })[0];
        if (action)
            requestAction(action, row);
    }

    function showLogs() {
        if (!hostWidget || !selectedRow.containerId)
            return;
        view = "logs";
        hostWidget.requestLogs(selectedRow.containerId);
    }

    // One step towards the list: logs -> detail -> list, settings -> list.
    function back() {
        if (view === "logs") {
            view = "detail";
            return;
        }
        if (detailParentId) {
            const parent = detailRow(detailParentId);
            detailParentId = "";
            if (parent) {
                selectedId = parent.id;
                selectedRow = parent;
                focusKeys();
                return;
            }
        }
        selectedId = "";
        selectedRow = {};
        view = "list";
    }

    function toggleSettings() {
        var leaving = view === "settings";
        if (view === "logs")
            back();
        detailParentId = "";
        back();
        if (!leaving)
            view = "settings";
    }

    function selectTab(name) {
        if (cfg.tabs.indexOf(name) < 0)
            return;
        detailParentId = "";
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

    onProjectOptionsChanged: {
        if (!projectOptions.some(function (p) {
            return p.value === root.toolProject;
        }))
            toolProject = projectOptions.length ? projectOptions[0].value : "";
    }
    onCfgChanged: {
        if (cfg.tabs.indexOf(tab) < 0)
            selectTab(cfg.tabs[0]);
    }
    onVisibleRowsChanged: {
        if (confirmation && !detailRow(confirmation.row.id)) {
            confirmation = null;
            focusKeys();
        }
        Model.sync(listModel, visibleRows);
        cursor = Math.max(0, Math.min(visibleRows.length - 1, cursor));
        if (!selectedId)
            return;
        const match = detailRow(selectedId);
        if (match) {
            selectedRow = match;
        } else {
            // The service went away while its details were open.
            if (view === "logs")
                back();
            back();
        }
    }
    onViewChanged: {
        if (view !== "logs") {
            logFollow = false;
            logQuery = "";
            if (hostWidget && hostWidget.logs.containerId)
                hostWidget.clearLogs();
        }
    }
    onOpenedChanged: {
        if (!opened)
            confirmation = null;
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

    Timer {
        objectName: "logFollowTimer"
        interval: 3000
        repeat: true
        running: root.opened && root.view === "logs" && root.logFollow && root.cfg.dockerEnabled && !!root.hostWidget && !!root.selectedRow.containerId
        onTriggered: root.hostWidget.requestLogs(root.selectedRow.containerId, true)
    }

    component Label: Text {
        textFormat: Text.PlainText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: root.fonts.body
    }

    Ui.KeyboardPanel {
        id: surface
        anchorItem: root.anchorItem
        owner: root.hostWidget || root
        bar: root.bar
        open: root.opened
        focusTarget: surface.loadedContent
        contentWidth: surface.fittedContentWidth(Style.space(560))
        contentHeight: surface.fittedContentHeight(surface.loadedContentHeight, Style.space(800))

        content: Component {
            Ui.PanelKeyCatcher {
                id: keys
                objectName: "keys"
                implicitHeight: column.implicitHeight
                blocked: root.confirming || listPage.searchField.activeFocus || detailPage.logSearchField.activeFocus || settingsForm.editing || projectPicker.popupOpen

                // A view change hides whatever input had focus; keys belong to the panel again.
                Connections {
                    target: root
                    function onViewChanged() {
                        if (!root.confirming)
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
                        listPage.listView.positionViewAtIndex(root.cursor, ListView.Contain);
                    } else if (root.view === "list") {
                        root.stepTab(dx);
                    } else if (dx < 0 && root.view !== "settings") {
                        root.back();
                    } else if (dx > 0 && root.view === "detail" && root.cfg.dockerEnabled) {
                        root.showLogs();
                    }
                }
                onDeleteRequested: root.shortcut("x")
                onActivateRequested: {
                    if (root.view === "list")
                        root.openDetail(root.cursor);
                }
                onTextKey: function (key, modifiers) {
                    if (modifiers & Qt.ShiftModifier)
                        key = key.toUpperCase();
                    if (modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier) || root.view === "settings")
                        return;
                    if (key === "r")
                        root.hostWidget.refresh();
                    else if (key === "c")
                        root.copyCurrent();
                    else if (key === "/" && root.view === "list")
                        listPage.searchField.forceActiveFocus();
                    else if (key === "/" && root.view === "logs")
                        detailPage.logSearchField.forceActiveFocus();
                    else if (key === "f" && root.view === "logs")
                        root.logFollow = !root.logFollow;
                    else if (key === "o" && root.view === "detail" && root.selectedRow.url)
                        root.openCurrent("");
                    else if (key === "s")
                        root.toggleSettings();
                    else if (Model.tabKey(key, root.cfg))
                        root.selectTab(Model.tabKey(key, root.cfg));
                    else
                        root.shortcut(key);
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
                                    objectName: "dashboardTitle"
                                    text: root.view === "settings" ? strings.t("panel.settingsTitle").arg(Model.displayName) : Model.displayName
                                    font.pixelSize: root.fonts.title
                                    font.bold: true
                                    elide: Text.ElideRight
                                }
                                Label {
                                    width: parent.width
                                    text: strings.t("panel.tagline")
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
                                    tooltipText: strings.t("panel.refresh")
                                    foreground: root.foreground
                                    horizontalPadding: root.gaps.md
                                    onClicked: root.hostWidget.refresh()
                                }
                                Ui.Button {
                                    // nf-md-cog
                                    iconText: "\u{f0493}"
                                    tooltipText: strings.t("panel.settings")
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
                                text: (root.hostWidget ? root.hostWidget.errorText : "") + "\n" + strings.t("panel.lastSample")
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
                                        text: Model.tabLabel(modelData, strings) + (root.sampled && modelData !== "Projects" && modelData !== "Tools" ? " " + (root.counts[modelData] || 0) : "")
                                        selected: root.tab === modelData
                                        bordered: true
                                        foreground: root.foreground
                                        onClicked: root.selectTab(modelData)
                                    }
                                }
                            }

                            Ui.Dropdown {
                                id: projectPicker
                                objectName: "projectPicker"
                                width: parent.width
                                visible: root.tab === "Tools"
                                label: strings.t("panel.launchInProject")
                                value: root.toolProject
                                options: root.projectOptions
                                foreground: root.foreground
                                onChanged: function (value) {
                                    root.toolProject = value;
                                }
                            }
                            Label {
                                width: parent.width
                                visible: root.tab === "Tools" && !root.projectOptions.length
                                text: strings.t("panel.noToolProject")
                                color: root.dim
                                wrapMode: Text.WordWrap
                            }
                            ListPage {
                                id: listPage
                                width: parent.width
                                panel: root
                            }
                        }

                        // ---- detail and logs ----------------------------------------------
                        DetailPage {
                            id: detailPage
                            width: parent.width
                            panel: root
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
                            text: root.operating ? root.hostWidget.operation.label : hasMessage ? root.hostWidget.message : root.view === "list" ? root.updatedText + (root.tab === "Tools" ? strings.t("keys.launch") : strings.t("keys.list")) + strings.t("keys.settings") : root.view === "settings" ? strings.t("keys.save") : root.view === "logs" ? strings.t("keys.log") : [strings.t("keys.back")].concat(Model.availableActions(root.selectedRow, root.cfg, root.inventory, strings).filter(function (a) {
                                return a.key;
                            }).map(function (a) {
                                return a.key + " " + a.label.toLowerCase();
                            })).concat(root.selectedRow.containerId && root.cfg.dockerEnabled ? [strings.t("keys.openLogs")] : []).join(" · ")
                            color: hasMessage && root.hostWidget.messageUrgent ? root.urgent : root.dim
                            font.pixelSize: root.fonts.caption
                            elide: Text.ElideRight
                            maximumLineCount: 2
                            wrapMode: Text.WordWrap
                        }
                    }
                }

                ConfirmSheet {
                    anchors.fill: parent
                    opened: root.confirming
                    message: root.confirmation ? Model.confirmText(root.confirmation.op, root.confirmation.row, strings) : ""
                    cancelLabel: strings.t("common.cancel")
                    confirmLabel: strings.t("common.confirm")
                    foreground: root.foreground
                    onCanceled: {
                        root.confirmation = null;
                        keys.forceActiveFocus();
                    }
                    onConfirmed: {
                        root.confirmAction();
                        keys.forceActiveFocus();
                    }
                }
            }
        }
    }
}
