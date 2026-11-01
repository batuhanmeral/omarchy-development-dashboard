import QtQuick

Item {
    property var bar: null
    property string text: ""
    property string labelText: ""
    property string tooltipText: ""
    property bool active: false
    property real slotSize: 27
    property string fontFamily: "Sans Serif"
    property real fontSize: 13
    signal pressed(int button)
    implicitWidth: slotSize
    implicitHeight: 26
}
