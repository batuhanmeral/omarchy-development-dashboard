pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui
import "Model.js" as Model

Ui.Panel {
    id: root
    readonly property var fonts: Style.font
    readonly property var popupColors: Commons.Color.popups
    moduleName: "io.github.batuhanmeral.devports"
    manageIpc: false
    readonly property var hostBar: bar
    property Item anchorItem: null
    property var hostWidget: null
    property string tab: "Localhost"
    property string query: ""
    property string filter: "all"
    property bool showSettings: false
    property bool showLogs: false
    property string selectedId: ""
    property var selectedRow: ({})
    readonly property var cfg: hostWidget ? hostWidget.cfg : Model.config({})
    readonly property var inventory: hostWidget ? hostWidget.inventory : ({})
    readonly property var visibleRows: Model.rows(inventory, tab, query, filter, cfg)
    readonly property var filterOptions: tab === "Localhost" ? ["all", "localhost", "lan"] : tab === "Images" ? ["all", "images", "volumes", "unused"] : ["all", "running", "stopped"]

    function switchPanel(direction) {
        return root.bar && typeof root.hostBar.switchPanelFrom === "function" ? root.hostBar.switchPanelFrom(root.hostWidget || root, direction) : false;
    }
    function select(row) {
        if (hostWidget)
            hostWidget.clearLogs();
        selectedId = row.id;
        selectedRow = row;
        showLogs = false;
    }
    function back() {
        selectedId = "";
        selectedRow = {};
        showLogs = false;
        if (hostWidget)
            hostWidget.clearLogs();
    }
    function selectTab(name) {
        tab = name;
        filter = "all";
        query = "";
        back();
    }
    onCfgChanged: {
        if (cfg.tabs.indexOf(tab) < 0)
            selectTab(cfg.tabs[0]);
    }
    onVisibleRowsChanged: {
        Model.sync(listModel, visibleRows);
        if (selectedId) {
            let match = visibleRows.filter(function (row) {
                return row.id === root.selectedId;
            });
            if (match.length)
                selectedRow = match[0];
            else
                back();
        }
    }
    onOpenedChanged: if (!opened) {
        showLogs = false;
        showSettings = false;
    }

    ListModel {
        id: listModel
    }

    component Label: Text {
        textFormat: Text.PlainText
        color: root.popupColors.text
        font.family: root.fonts.family
        font.pixelSize: root.fonts.body
    }

    Ui.KeyboardPanel {
        id: surface
        anchorItem: root.anchorItem
        owner: root.hostWidget || root
        bar: root.bar
        open: root.opened
        focusTarget: surface.loadedContent
        contentWidth: surface.fittedContentWidth(Style.space(480))
        contentHeight: surface.fittedContentHeight(Style.space(580))
        content: Component {
            Ui.PanelKeyCatcher {
                id: catcher
                implicitHeight: Style.space(580)
                onCloseRequested: root.close()
                onTabRequested: function (direction) {
                    root.switchPanel(direction);
                }
                onMoveRequested: function (dx, dy) {
                    if (!root.selectedId && !root.showSettings)
                        serviceList.currentIndex = Math.max(0, Math.min(listModel.count - 1, serviceList.currentIndex + dy));
                }
                onActivateRequested: {
                    if (!root.selectedId && listModel.count && !root.showSettings)
                        root.select(root.visibleRows[serviceList.currentIndex]);
                }

                ColumnLayout {
                    anchors.fill: parent
                    spacing: Style.space(10)
                    RowLayout {
                        Layout.fillWidth: true
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: Style.space(2)
                            Label {
                                text: "Development Ports"
                                font.pixelSize: root.fonts.subtitle
                                font.bold: true
                            }
                            Label {
                                text: root.hostWidget && root.hostWidget.busy ? "Refreshing…" : "Local services · read-only"
                                color: Commons.Color.muted
                            }
                        }
                        ActionButton {
                            text: "↻"
                            Accessible.name: "Refresh data"
                            enabled: root.hostWidget && !root.hostWidget.busy
                            onClicked: if (root.hostWidget)
                                root.hostWidget.refresh()
                        }
                        ActionButton {
                            text: "⚙"
                            Accessible.name: "Settings"
                            selected: root.showSettings
                            onClicked: {
                                root.showSettings = !root.showSettings;
                                if (root.showSettings)
                                    settingsForm.load();
                            }
                        }
                        ActionButton {
                            text: "×"
                            Accessible.name: "Close panel"
                            onClicked: root.close()
                        }
                    }
                    Label {
                        Layout.fillWidth: true
                        visible: root.hostWidget && root.hostWidget.hasError
                        text: root.hostWidget ? root.hostWidget.errorText + "\nPrevious data may be stale." : ""
                        color: Commons.Color.urgent
                        wrapMode: Text.WordWrap
                        maximumLineCount: 4
                        elide: Text.ElideRight
                    }
                    Label {
                        Layout.fillWidth: true
                        visible: root.hostWidget && root.hostWidget.message !== ""
                        text: root.hostWidget ? root.hostWidget.message : ""
                        wrapMode: Text.WordWrap
                        color: Commons.Color.muted
                        maximumLineCount: 3
                        elide: Text.ElideRight
                    }
                    ScrollView {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        visible: root.showSettings
                        clip: true
                        contentWidth: availableWidth
                        Settings {
                            id: settingsForm
                            width: parent.width
                            values: root.hostWidget ? root.hostWidget.settings : ({})
                            onSaveRequested: function (values) {
                                if (root.hostWidget && root.hostWidget.saveSettings(values))
                                    root.showSettings = false;
                            }
                            onCancelRequested: root.showSettings = false
                        }
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        visible: !root.showSettings
                        spacing: Style.space(8)
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Style.space(4)
                            Repeater {
                                model: root.cfg.tabs
                                ActionButton {
                                    required property string modelData
                                    Layout.fillWidth: true
                                    Layout.minimumWidth: 0
                                    text: modelData
                                    selected: root.tab === modelData
                                    onClicked: root.selectTab(modelData)
                                }
                            }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            visible: !root.selectedId
                            TextField {
                                id: search
                                Layout.fillWidth: true
                                Layout.minimumWidth: 0
                                text: root.query
                                placeholderText: "Search " + root.tab.toLowerCase() + "…"
                                placeholderTextColor: Commons.Color.muted
                                color: root.popupColors.text
                                font.family: root.fonts.family
                                font.pixelSize: root.fonts.body
                                selectByMouse: true
                                onTextEdited: root.query = text
                                Keys.onEscapePressed: root.close()
                                background: Rectangle {
                                    color: Qt.alpha(Commons.Color.accent, 0.05)
                                    radius: Style.space(5)
                                    border.color: Qt.alpha(Commons.Color.accent, search.activeFocus ? 0.7 : 0.2)
                                }
                            }
                            ComboBox {
                                id: filterBox
                                Layout.preferredWidth: Style.space(112)
                                model: root.filterOptions
                                currentIndex: root.filterOptions.indexOf(root.filter)
                                onActivated: root.filter = root.filterOptions[currentIndex]
                                palette.text: root.popupColors.text
                                palette.buttonText: root.popupColors.text
                                palette.button: Commons.Color.background
                                palette.base: Commons.Color.background
                            }
                        }
                        Label {
                            Layout.fillWidth: true
                            visible: root.tab !== "Localhost" && (!root.cfg.dockerEnabled || root.inventory.dockerStatus === "unavailable")
                            text: root.cfg.dockerEnabled ? "Docker unavailable" : "Docker integration disabled"
                            color: Commons.Color.muted
                        }
                        ListView {
                            id: serviceList
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            visible: !root.selectedId
                            clip: true
                            model: listModel
                            spacing: Style.space(4)
                            currentIndex: 0
                            reuseItems: true
                            ScrollBar.vertical: ScrollBar {}
                            delegate: Rectangle {
                                id: rowItem
                                required property int index
                                required property string title
                                required property string subtitle
                                required property string badge
                                required property string rowState
                                width: serviceList.width
                                height: Style.space(root.cfg.compact ? 52 : 66)
                                radius: Math.max(Style.space(5), Style.cornerRadius)
                                color: Qt.alpha(Commons.Color.accent, rowMouse.containsMouse || serviceList.currentIndex === index ? 0.10 : 0.04)
                                border.width: serviceList.currentIndex === index ? 1 : 0
                                border.color: Qt.alpha(Commons.Color.accent, 0.2)
                                RowLayout {
                                    anchors.fill: parent
                                    anchors.margins: Style.space(10)
                                    spacing: Style.space(10)
                                    Rectangle {
                                        implicitWidth: Style.space(6)
                                        implicitHeight: implicitWidth
                                        radius: width / 2
                                        color: rowItem.rowState === "running" ? Commons.Color.accent : Commons.Color.muted
                                    }
                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        Layout.minimumWidth: 0
                                        spacing: Style.space(2)
                                        Label {
                                            Layout.fillWidth: true
                                            text: rowItem.title
                                            elide: Text.ElideRight
                                            font.bold: true
                                        }
                                        Label {
                                            Layout.fillWidth: true
                                            text: rowItem.subtitle
                                            elide: Text.ElideRight
                                            color: Commons.Color.muted
                                        }
                                    }
                                    Label {
                                        text: rowItem.badge
                                        Layout.maximumWidth: Style.space(94)
                                        elide: Text.ElideRight
                                        color: rowItem.badge === "all" ? Commons.Color.urgent : Commons.Color.muted
                                    }
                                }
                                MouseArea {
                                    id: rowMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        serviceList.currentIndex = rowItem.index;
                                        root.select(root.visibleRows[rowItem.index]);
                                    }
                                }
                            }
                            Label {
                                anchors.centerIn: parent
                                width: parent.width - Style.space(24)
                                horizontalAlignment: Text.AlignHCenter
                                wrapMode: Text.WordWrap
                                visible: listModel.count === 0
                                color: Commons.Color.muted
                                text: root.hostWidget && root.hostWidget.busy ? "Collecting local inventory…" : "No matching entries.\nTry another filter or refresh."
                            }
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            visible: !!root.selectedId
                            RowLayout {
                                Layout.fillWidth: true
                                ActionButton {
                                    text: "← Back"
                                    onClicked: root.back()
                                }
                                Label {
                                    Layout.fillWidth: true
                                    text: root.selectedRow.title || ""
                                    font.bold: true
                                    elide: Text.ElideRight
                                }
                            }
                            ScrollView {
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                clip: true
                                contentWidth: availableWidth
                                TextArea {
                                    width: parent.width
                                    readOnly: true
                                    selectByMouse: true
                                    textFormat: TextEdit.PlainText
                                    wrapMode: TextEdit.Wrap
                                    color: root.popupColors.text
                                    font.family: root.fonts.family
                                    font.pixelSize: root.fonts.body
                                    text: root.showLogs && root.hostWidget ? root.hostWidget.logText : root.selectedRow.detail || ""
                                    background: null
                                    Keys.onEscapePressed: root.close()
                                }
                            }
                            Flow {
                                Layout.fillWidth: true
                                Layout.preferredHeight: childrenRect.height
                                spacing: Style.space(6)
                                ActionButton {
                                    text: root.selectedRow.url ? "Copy URL" : "Copy endpoint"
                                    visible: !!root.selectedRow.copyText
                                    onClicked: if (root.hostWidget)
                                        root.hostWidget.copyText(root.selectedRow.copyText)
                                }
                                ActionButton {
                                    text: "Open in browser"
                                    visible: !!root.selectedRow.url
                                    onClicked: if (root.hostWidget)
                                        root.hostWidget.openUrl(JSON.parse(root.selectedRow.raw), "")
                                }
                                ActionButton {
                                    text: root.showLogs ? "Process / container details" : "Read logs"
                                    visible: !!root.selectedRow.containerId && root.cfg.dockerEnabled
                                    enabled: root.hostWidget && !root.hostWidget.busy
                                    onClicked: {
                                        root.showLogs = !root.showLogs;
                                        if (root.showLogs && root.hostWidget)
                                            root.hostWidget.request("logs", root.selectedRow.containerId);
                                        else if (root.hostWidget)
                                            root.hostWidget.clearLogs();
                                    }
                                }
                            }
                            RowLayout {
                                visible: root.selectedRow.kind === "port" && !root.selectedRow.url && root.selectedRow.raw && !JSON.parse(root.selectedRow.raw).database
                                Layout.fillWidth: true
                                Label {
                                    text: "Known web service?"
                                    color: Commons.Color.muted
                                    Layout.fillWidth: true
                                }
                                ActionButton {
                                    text: "Open HTTP"
                                    onClicked: if (root.hostWidget)
                                        root.hostWidget.openUrl(JSON.parse(root.selectedRow.raw), "http")
                                }
                                ActionButton {
                                    text: "Open HTTPS"
                                    onClicked: if (root.hostWidget)
                                        root.hostWidget.openUrl(JSON.parse(root.selectedRow.raw), "https")
                                }
                            }
                            Label {
                                visible: root.showLogs
                                Layout.fillWidth: true
                                text: "Last 100 lines · logs can contain application secrets. Not saved to disk."
                                color: Commons.Color.muted
                                wrapMode: Text.WordWrap
                            }
                        }
                        Label {
                            Layout.fillWidth: true
                            text: listModel.count + " entries · " + (root.hostWidget && root.hostWidget.lastSuccess.ports ? "ports updated " + new Date(root.hostWidget.lastSuccess.ports).toLocaleTimeString() : "waiting for first sample")
                            color: Commons.Color.muted
                        }
                    }
                }
            }
        }
    }
}
