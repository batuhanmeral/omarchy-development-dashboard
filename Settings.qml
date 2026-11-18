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
    property bool managementEnabled: true
    property bool statusBadge: false
    property string terminal: "default"
    // Style and Color expose their token groups as plain QtObjects; `var` aliases keep qmllint quiet.
    readonly property var fonts: Style.font
    readonly property var gaps: Style.spacing
    readonly property var popupColors: Commons.Color.popups
    readonly property var intervalField: intervalInput.field
    readonly property var depthField: depthInput.field
    property color foreground: popupColors.text
    readonly property color dim: Qt.darker(foreground, 1.4)
    property var validationIssues: []
    readonly property string validationError: Model.validationMessages(validationIssues, strings).join("\n")
    readonly property bool editing: intervalField.activeFocus || portsInput.activeFocus || sqliteInput.activeFocus || rootsInput.activeFocus || toolsInput.activeFocus || editorInput.activeFocus || depthInput.field.activeFocus

    property bool dockerEnabled: true
    property bool compact: true
    property string exposure: "all"
    property string sortBy: "port"
    property var tabs: Model.tabNames

    signal saveRequested(var values)
    signal cancelRequested

    spacing: gaps.lg

    Commons.Translations {
        id: strings
        directory: Qt.resolvedUrl("i18n")
    }

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
        managementEnabled = cfg.managementEnabled;
        statusBadge = cfg.statusBadge;
        terminal = cfg.terminal;
        rootsInput.text = cfg.projectRoots;
        depthInput.value = cfg.projectDepth;
        editorInput.text = cfg.editor;
        toolsInput.text = cfg.customTools;
        validationIssues = [];
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
            statusBadge: statusBadge,
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
        validationIssues = Model.validationIssues(next);
        if (!validationIssues.length)
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

    Ui.Toggle {
        width: parent.width
        label: strings.t("settings.management")
        description: strings.t("settings.managementHelp")
        checked: root.managementEnabled
        foreground: root.foreground
        onClicked: root.managementEnabled = !root.managementEnabled
    }
    Column {
        width: parent.width
        spacing: root.gaps.md
        FieldLabel {
            text: strings.t("settings.projectFolders")
        }
        PlainArea {
            id: rootsInput
            objectName: "projectRoots"
            placeholderText: "/home/me/Projects"
        }
        Ui.NumberField {
            id: depthInput
            objectName: "projectDepth"
            label: strings.t("settings.scanDepth")
            from: 1
            to: 4
            foreground: root.foreground
        }
        FieldLabel {
            text: strings.t("action.terminal")
        }
        Ui.ButtonGroup {
            options: Model.terminals.map(function (name) {
                return {
                    value: name,
                    label: name === "default" ? strings.t("settings.defaultTerminal") : name
                };
            })
            value: root.terminal
            foreground: root.foreground
            onChanged: function (value) {
                root.terminal = value;
            }
        }
        FieldLabel {
            text: strings.t("action.editor")
        }
        Ui.TextField {
            id: editorInput
            objectName: "editor"
            width: parent.width
            placeholderText: strings.t("settings.editorPlaceholder")
            foreground: root.foreground
        }
        FieldLabel {
            text: strings.t("settings.customTools")
        }
        PlainArea {
            id: toolsInput
            objectName: "customTools"
            placeholderText: "Aider | aider | --no-auto-commits"
        }
    }

    Ui.Toggle {
        width: parent.width
        label: strings.t("tab.docker")
        description: strings.t("settings.dockerHelp")
        checked: root.dockerEnabled
        foreground: root.foreground
        onClicked: root.dockerEnabled = !root.dockerEnabled
    }

    Ui.Toggle {
        width: parent.width
        objectName: "statusBadge"
        label: strings.t("settings.badge")
        description: strings.t("settings.badgeHelp")
        checked: root.statusBadge
        foreground: root.foreground
        onClicked: root.statusBadge = !root.statusBadge
    }

    Ui.Toggle {
        width: parent.width
        label: strings.t("settings.compact")
        description: strings.t("settings.compactHelp")
        checked: root.compact
        foreground: root.foreground
        onClicked: root.compact = !root.compact
    }

    Ui.NumberField {
        id: intervalInput
        objectName: "refreshInterval"
        label: strings.t("settings.interval")
        from: 2
        to: 120
        foreground: root.foreground
    }

    Column {
        width: parent.width
        spacing: root.gaps.md
        FieldLabel {
            text: strings.t("settings.showPorts")
        }
        Ui.ButtonGroup {
            options: [
                {
                    value: "all",
                    label: strings.t("filter.all")
                },
                {
                    value: "localhost",
                    label: strings.t("settings.localOnly")
                },
                {
                    value: "lan",
                    label: strings.t("settings.exposedOnly")
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
            text: strings.t("settings.sort")
        }
        Ui.ButtonGroup {
            options: [
                {
                    value: "port",
                    label: strings.t("settings.sortPort")
                },
                {
                    value: "name",
                    label: strings.t("fact.name")
                },
                {
                    value: "state",
                    label: strings.t("fact.state")
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
            text: strings.t("settings.tabs")
        }
        Flow {
            width: parent.width
            spacing: root.gaps.md
            Repeater {
                id: tabButtons
                model: Model.tabNames
                Ui.Button {
                    required property string modelData
                    text: Model.tabLabel(modelData, strings)
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
            text: strings.t("settings.hiddenPorts")
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
            text: strings.t("settings.sqlite")
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
            text: strings.t("common.save")
            bordered: true
            focusable: true
            selected: true
            foreground: root.foreground
            onClicked: root.submit()
        }
        Ui.Button {
            text: strings.t("common.cancel")
            bordered: true
            focusable: true
            foreground: root.foreground
            onClicked: root.cancelRequested()
        }
    }
}
