pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import qs.Commons
import qs.Commons as Commons

Button {
    id: root
    readonly property var fonts: Style.font
    readonly property var popupColors: Commons.Color.popups
    property bool selected: false
    implicitHeight: Style.space(30)
    implicitWidth: label.implicitWidth + Style.space(20)
    padding: Style.space(6)
    opacity: enabled ? 1 : 0.4
    contentItem: Text {
        id: label
        text: root.text
        textFormat: Text.PlainText
        color: root.popupColors.text
        font.family: root.fonts.family
        font.pixelSize: root.fonts.body
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
    }
    background: Rectangle {
        radius: Math.max(Style.space(5), Style.cornerRadius)
        color: Qt.alpha(Commons.Color.accent, root.down ? 0.25 : root.selected ? 0.18 : root.hovered ? 0.1 : 0.04)
        border.width: root.activeFocus ? 2 : 1
        border.color: Qt.alpha(Commons.Color.accent, root.activeFocus ? 0.8 : 0.18)
    }
}
