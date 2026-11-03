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
    property var legacy: ({})
    property bool imported: false
    property bool managementEnabled: false
    property string terminal: "default"
    // Style and Color expose their token groups as plain QtObjects; `var` aliases keep qmllint quiet.
    readonly property var fonts: Style.font
    readonly property var gaps: Style.spacing
    readonly property var popupColors: Commons.Color.popups
    readonly property var intervalField: intervalInput.field
    readonly property var depthField: depthInput.field
    property color foreground: popupColors.text
    readonly property color dim: Qt.darker(foreground, 1.4)
    property string validationError: ""
    readonly property bool editing: intervalField.activeFocus || portsInput.activeFocus || sqliteInput.activeFocus || rootsInput.activeFocus || toolsInput.activeFocus || editorInput.activeFocus || depthInput.field.activeFocus

    property bool dockerEnabled: true
    property bool compact: true
    property string exposure: "all"
    property string sortBy: "port"
    property var tabs: Model.tabNames

    signal saveRequested(var values)
    signal copyRequested(string text)
    signal cancelRequested

    spacing: gaps.lg

    function load(source) {
        var cfg = Model.config(source === undefined ? values : source);
        intervalInput.value = cfg.refreshInterval;
        dockerEnabled = cfg.dockerEnabled;
        exposure = cfg.exposure;
        sortBy = cfg.sortBy;
        tabs = cfg.tabs.slice();
        compact = cfg.compact;
        portsInput.text = cfg.hiddenPorts;
        sqliteInput.text = cfg.sqliteFiles;
        managementEnabled = cfg.managementEnabled;
        terminal = cfg.terminal;
        rootsInput.text = cfg.projectRoots;
        depthInput.value = cfg.projectDepth;
        editorInput.text = cfg.editor;
        toolsInput.text = cfg.customTools;
        imported = false;
        validationError = "";
    }

    function importLegacy() {
        if (!legacy.found)
            return;
        var normalized = Model.legacySettings(legacy.settings);
        var importedValues = {};
        ["refreshInterval", "dockerEnabled", "exposure", "hiddenPorts", "visibleTabs", "sortBy", "compact", "sqliteFiles"].forEach(function (key) {
            importedValues[key] = normalized[key];
        });
        load(Object.assign({}, values, importedValues));
        imported = true;
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
        var depthSpin = depthField;
        var depth = depthSpin.contentItem ? depthSpin.valueFromText(depthSpin.contentItem.text, depthSpin.locale) : depthSpin.value;
        var next = {
            settingsVersion: 2,
            managementEnabled: managementEnabled,
            projectRoots: rootsInput.text.trim(),
            projectDepth: depth,
            terminal: terminal,
            editor: editorInput.text.trim(),
            customTools: toolsInput.text.trim(),
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

    component PlainArea: QQC.TextArea {
        width: parent.width
        height: Style.space(70)
        color: root.foreground
        placeholderTextColor: root.dim
        textFormat: TextEdit.PlainText
        wrapMode: TextEdit.WrapAnywhere
        selectByMouse: true
        font.family: root.fonts.family
        font.pixelSize: root.fonts.body
        background: Rectangle {
            color: "transparent"
            border.color: root.dim
            radius: Style.cornerRadius
        }
    }

    Column {
        width: parent.width
        spacing: root.gaps.md
        visible: root.legacy.found === true || root.legacy.installed === true
        FieldLabel {
            width: parent.width
            wrapMode: Text.WordWrap
            text: root.imported ? "Review and press Save. The old plugin's settings are not changed." : "Settings from Development Ports are available to import."
            visible: root.legacy.found === true
        }
        Ui.Button {
            width: parent.width
            objectName: "importLegacy"
            visible: root.legacy.found === true
            text: "Import settings from Development Ports"
            bordered: true
            foreground: root.foreground
            onClicked: root.importLegacy()
        }
        FieldLabel {
            width: parent.width
            visible: root.legacy.installed === true
            wrapMode: Text.WrapAnywhere
            text: "Remove the old plugin when done: omarchy plugin remove " + Model.legacyPluginId
        }
        Ui.Button {
            visible: root.legacy.installed === true
            text: "Copy removal command"
            bordered: true
            foreground: root.foreground
            onClicked: root.copyRequested("omarchy plugin remove " + Model.legacyPluginId)
        }
    }

    Ui.Toggle {
        width: parent.width
        label: "Management actions"
        description: "Start, stop and restart containers and stop your own development processes. Every action is started by you; disruptive ones ask first."
        checked: root.managementEnabled
        foreground: root.foreground
        onClicked: root.managementEnabled = !root.managementEnabled
    }
    Column {
        width: parent.width
        spacing: root.gaps.md
        FieldLabel {
            text: "Project folders"
        }
        PlainArea {
            id: rootsInput
            objectName: "projectRoots"
            placeholderText: "/home/me/Projects"
        }
        Ui.NumberField {
            id: depthInput
            objectName: "projectDepth"
            label: "Scan depth"
            from: 1
            to: 4
            foreground: root.foreground
        }
        FieldLabel {
            text: "Terminal"
        }
        Ui.ButtonGroup {
            options: Model.terminals.map(function (name) {
                return {
                    value: name,
                    label: name === "default" ? "Default" : name
                };
            })
            value: root.terminal
            foreground: root.foreground
            onChanged: function (value) {
                root.terminal = value;
            }
        }
        FieldLabel {
            text: "Editor"
        }
        Ui.TextField {
            id: editorInput
            objectName: "editor"
            width: parent.width
            placeholderText: "Omarchy default editor"
            foreground: root.foreground
        }
        FieldLabel {
            text: "Custom AI tools"
        }
        PlainArea {
            id: toolsInput
            objectName: "customTools"
            placeholderText: "Aider | aider | --no-auto-commits"
        }
    }

    Ui.Toggle {
        width: parent.width
        label: "Docker"
        description: "List containers, images and volumes."
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
        Flow {
            width: parent.width
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
