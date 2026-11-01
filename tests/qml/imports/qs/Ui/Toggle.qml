import QtQuick

// Test stand-in for Omarchy's qs.Ui.Toggle: the caller owns `checked` and flips it on clicked().
Item {
    property string label: ""
    property string description: ""
    property bool checked: false
    property color foreground: "white"
    signal clicked
    implicitWidth: 240
    implicitHeight: 54
}
