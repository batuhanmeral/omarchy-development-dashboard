pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import "Model.js" as Model

ColumnLayout {
    id: root
    readonly property var fonts: Style.font
    readonly property var popupColors: Commons.Color.popups
    property var values: ({})
    property string validationError: ""
    signal saveRequested(var values)
    signal cancelRequested
    spacing: Style.space(8)

    function load() {
        var cfg = Model.config(values);
        intervalInput.value = cfg.refreshInterval;
        dockerInput.checked = cfg.dockerEnabled;
        exposureInput.currentIndex = ["all", "localhost", "lan"].indexOf(cfg.exposure);
        portsInput.text = cfg.hiddenPorts;
        sortInput.currentIndex = ["port", "name", "state"].indexOf(cfg.sortBy);
        compactInput.checked = cfg.compact;
        sqliteInput.text = cfg.sqliteFiles;
        for (var i = 0; i < tabChecks.count; i++)
            tabChecks.itemAt(i).checked = cfg.tabs.indexOf(tabChecks.itemAt(i).text) >= 0;
        validationError = "";
    }
    function submit() {
        var tabs = [];
        for (var i = 0; i < tabChecks.count; i++) {
            const check = tabChecks.itemAt(i) as CheckBox;
            if (check.checked)
                tabs.push(check.text);
        }
        var next = {
            refreshInterval: intervalInput.value,
            dockerEnabled: dockerInput.checked,
            exposure: ["all", "localhost", "lan"][exposureInput.currentIndex],
            hiddenPorts: portsInput.text,
            visibleTabs: tabs.join(","),
            sortBy: ["port", "name", "state"][sortInput.currentIndex],
            compact: compactInput.checked,
            sqliteFiles: sqliteInput.text
        };
        var errors = Model.validateSettings(next);
        validationError = errors.join("\n");
        if (!errors.length)
            saveRequested(next);
    }
    Component.onCompleted: load()

    Text {
        text: "Settings"
        color: root.popupColors.text
        font.family: root.fonts.family
        font.pixelSize: root.fonts.subtitle
        font.bold: true
    }
    RowLayout {
        Layout.fillWidth: true
        Text {
            text: "Refresh (seconds)"
            color: root.popupColors.text
            Layout.fillWidth: true
        }
        SpinBox {
            id: intervalInput
            from: 2
            to: 120
            editable: true
            palette.text: root.popupColors.text
            palette.button: Commons.Color.background
            palette.base: Commons.Color.background
        }
    }
    CheckBox {
        id: dockerInput
        text: "Docker integration (read-only)"
        palette.windowText: root.popupColors.text
    }
    RowLayout {
        Layout.fillWidth: true
        Text {
            text: "Exposure"
            color: root.popupColors.text
            Layout.fillWidth: true
        }
        ComboBox {
            id: exposureInput
            model: ["All bindings", "Localhost only", "LAN / all interfaces"]
            palette.text: root.popupColors.text
            palette.buttonText: root.popupColors.text
            palette.button: Commons.Color.background
            palette.base: Commons.Color.background
        }
    }
    TextField {
        id: portsInput
        Layout.fillWidth: true
        placeholderText: "Hidden ports, e.g. 53,631,8000-8010"
        color: root.popupColors.text
        placeholderTextColor: Commons.Color.muted
        background: Rectangle {
            color: Qt.alpha(Commons.Color.accent, 0.06)
            radius: Style.space(5)
            border.color: Qt.alpha(Commons.Color.accent, 0.25)
        }
    }
    Text {
        text: "Visible tabs"
        color: root.popupColors.text
    }
    Flow {
        Layout.fillWidth: true
        Layout.preferredHeight: childrenRect.height
        Repeater {
            id: tabChecks
            model: ["Localhost", "Docker", "Images", "Databases"]
            CheckBox {
                required property string modelData
                text: modelData
                palette.windowText: root.popupColors.text
            }
        }
    }
    RowLayout {
        Layout.fillWidth: true
        Text {
            text: "Sort"
            color: root.popupColors.text
            Layout.fillWidth: true
        }
        ComboBox {
            id: sortInput
            model: ["Port", "Name", "State"]
            palette.text: root.popupColors.text
            palette.buttonText: root.popupColors.text
            palette.button: Commons.Color.background
            palette.base: Commons.Color.background
        }
    }
    CheckBox {
        id: compactInput
        text: "Compact rows"
        palette.windowText: root.popupColors.text
    }
    Text {
        text: "SQLite files (optional, absolute paths)"
        color: root.popupColors.text
    }
    TextArea {
        id: sqliteInput
        Layout.fillWidth: true
        Layout.preferredHeight: Style.space(76)
        placeholderText: "One configured file per line; contents are never read"
        placeholderTextColor: Commons.Color.muted
        color: root.popupColors.text
        textFormat: TextEdit.PlainText
        wrapMode: TextEdit.Wrap
        selectByMouse: true
        background: Rectangle {
            color: Qt.alpha(Commons.Color.accent, 0.06)
            radius: Style.space(5)
            border.color: Qt.alpha(Commons.Color.accent, 0.25)
        }
    }
    Text {
        Layout.fillWidth: true
        visible: root.validationError !== ""
        text: root.validationError
        textFormat: Text.PlainText
        color: Commons.Color.urgent
        wrapMode: Text.WordWrap
    }
    RowLayout {
        ActionButton {
            text: "Save settings"
            onClicked: root.submit()
        }
        ActionButton {
            text: "Cancel"
            onClicked: root.cancelRequested()
        }
    }
}
