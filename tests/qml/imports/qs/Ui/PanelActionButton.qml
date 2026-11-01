import QtQuick

Item {
    property string iconText: ""
    property string tooltipText: ""
    property bool bordered: false
    property color foreground: "white"
    signal clicked
    implicitWidth: 22
    implicitHeight: 22
}
