import QtQuick

// Test stand-in for Omarchy's qs.Ui.ButtonGroup.
Item {
    property var options: []
    property real spacing: 6
    property string value: ""
    property bool focusable: true
    property real fontSize: 12
    property color foreground: "white"
    signal changed(string value)
    implicitWidth: 180
    implicitHeight: 24
}
