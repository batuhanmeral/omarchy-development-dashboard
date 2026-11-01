pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as QQC
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui
import "Model.js" as Model

// Settings form. It edits a draft and reports it through saveRequested; storing is up to the
// caller. `editing` is true while a text input has focus, so the panel can stop treating
// letters as shortcuts.
Column {
    id: root

    property var values: ({})
    // Style and Color expose their token groups as plain QtObjects; `var` aliases keep qmllint quiet.
    readonly property var fonts: Style.font
    readonly property var gaps: Style.spacing
    readonly property var popupColors: Commons.Color.popups
    readonly property var intervalField: intervalInput.field
    property color foreground: popupColors.text
    readonly property color dim: Qt.darker(foreground, 1.4)
    property string validationError: ""
    readonly property bool editing: intervalField.activeFocus || portsInput.activeFocus || sqliteInput.activeFocus

    property bool dockerEnabled: true
    property bool compact: true
    property string exposure: "all"
    property string sortBy: "port"
    property var tabs: Model.tabNames

    signal saveRequested(var values)
    signal cancelRequested

    spacing: gaps.lg

    function load() {
        var cfg = Model.config(values);
        intervalInput.value = cfg.refreshInterval;
        dockerEnabled = cfg.dockerEnabled;
        exposure = cfg.exposure;
        sortBy = cfg.sortBy;
        tabs = cfg.tabs.slice();
        compact = cfg.compact;
        portsInput.text = cfg.hiddenPorts;
        sqliteInput.text = cfg.sqliteFiles;
        validationError = "";
    }

    function toggleTab(name) {
        tabs = Model.tabNames.filter(function (tab) {
            return (tabs.indexOf(tab) >= 0) !== (tab === name);
        });
    }

    function submit() {
        // Read the typed text: a SpinBox only commits its value when it loses focus.
        var spin = intervalField;
        var typed = spin.contentItem ? spin.valueFromText(spin.contentItem.text, spin.locale) : spin.value;
        var next = {
            refreshInterval: typed,
            dockerEnabled: dockerEnabled,
            exposure: exposure,
            hiddenPorts: portsInput.text.trim(),
            visibleTabs: tabs.join(","),
            sortBy: sortBy,
            compact: compact,
            sqliteFiles: sqliteInput.text.trim()
        };
        var errors = Model.validateSettings(next);
        validationError = errors.join("\n");
        if (!errors.length)
            saveRequested(next);
    }

    Component.onCompleted: load()
    Keys.onEscapePressed: cancelRequested()

    component FieldLabel: Text {
        textFormat: Text.PlainText
        color: root.dim
        font.family: root.fonts.family
        font.pixelSize: root.fonts.bodySmall
    }

    Ui.Toggle {
        width: parent.width
        label: "Docker"
        description: "List containers, images and volumes. Read-only."
        checked: root.dockerEnabled
        foreground: root.foreground
        onClicked: root.dockerEnabled = !root.dockerEnabled
    }

    Ui.Toggle {
        width: parent.width
        label: "Compact rows"
        description: "Fit more entries in the list."
        checked: root.compact
        foreground: root.foreground
        onClicked: root.compact = !root.compact
    }

    Ui.NumberField {
        id: intervalInput
        objectName: "refreshInterval"
        label: "Refresh interval while open (seconds)"
        from: 2
        to: 120
        foreground: root.foreground
    }

    Column {
        width: parent.width
        spacing: root.gaps.md
        FieldLabel {
            text: "Show ports"
        }
        Ui.ButtonGroup {
            options: [
                {
                    value: "all",
                    label: "All"
                },
                {
                    value: "localhost",
                    label: "Local only"
                },
                {
                    value: "lan",
                    label: "Exposed only"
                }
            ]
            value: root.exposure
            foreground: root.foreground
            onChanged: function (value) {
                root.exposure = value;
            }
        }
    }

    Column {
        width: parent.width
        spacing: root.gaps.md
        FieldLabel {
            text: "Sort by"
        }
        Ui.ButtonGroup {
            options: [
                {
                    value: "port",
                    label: "Port"
                },
                {
                    value: "name",
                    label: "Name"
                },
                {
                    value: "state",
                    label: "State"
                }
            ]
            value: root.sortBy
            foreground: root.foreground
            onChanged: function (value) {
                root.sortBy = value;
            }
        }
    }

    Column {
        width: parent.width
        spacing: root.gaps.md
        FieldLabel {
            text: "Tabs"
        }
        Row {
            spacing: root.gaps.md
            Repeater {
                id: tabButtons
                model: Model.tabNames
                Ui.Button {
                    required property string modelData
                    text: Model.tabLabel(modelData)
                    selected: root.tabs.indexOf(modelData) >= 0
                    bordered: true
                    focusable: true
                    foreground: root.foreground
                    onClicked: root.toggleTab(modelData)
                }
            }
        }
    }

    Column {
        width: parent.width
        spacing: root.gaps.md
        FieldLabel {
            text: "Hidden ports"
        }
        Ui.TextField {
            id: portsInput
            objectName: "hiddenPorts"
            width: parent.width
            placeholderText: "53, 631, 8000-8010"
            foreground: root.foreground
        }
    }

    Column {
        width: parent.width
        spacing: root.gaps.md
        FieldLabel {
            text: "SQLite files (one absolute path per line; contents are never read)"
            width: parent.width
            wrapMode: Text.WordWrap
        }
        QQC.TextArea {
            id: sqliteInput
            width: parent.width
            height: Style.space(64)
            placeholderText: "/home/me/project/dev.db"
            placeholderTextColor: Qt.darker(root.foreground, 1.6)
            color: root.foreground
            selectionColor: Style.selectionFillFor(root.foreground, Commons.Color.accent)
            selectedTextColor: root.foreground
            font.family: root.fonts.family
            font.pixelSize: root.fonts.body
            textFormat: TextEdit.PlainText
            wrapMode: TextEdit.WrapAnywhere
            selectByMouse: true
            leftPadding: root.gaps.controlPaddingX
            rightPadding: root.gaps.controlPaddingX
            topPadding: root.gaps.inputPaddingY
            bottomPadding: root.gaps.inputPaddingY
            background: Rectangle {
                radius: Style.cornerRadius
                color: Style.controlFill(sqliteInput.activeFocus, sqliteInput.hovered, root.foreground, Commons.Color.accent)
                border.width: Style.normalBorderWidth
                border.color: Style.controlBorder(sqliteInput.activeFocus, sqliteInput.hovered, root.foreground, Commons.Color.accent)
            }
        }
    }

    Text {
        width: parent.width
        visible: root.validationError !== ""
        text: root.validationError
        textFormat: Text.PlainText
        color: Commons.Color.urgent
        font.family: root.fonts.family
        font.pixelSize: root.fonts.bodySmall
        wrapMode: Text.WordWrap
    }

    Row {
        spacing: root.gaps.md
        Ui.Button {
            objectName: "save"
            text: "Save"
            bordered: true
            focusable: true
            selected: true
            foreground: root.foreground
            onClicked: root.submit()
        }
        Ui.Button {
            text: "Cancel"
            bordered: true
            focusable: true
            foreground: root.foreground
            onClicked: root.cancelRequested()
        }
    }
}
