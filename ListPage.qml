pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts
import qs.Commons
import qs.Ui as Ui
import "Model.js" as Model

Column {
    id: root
    required property var panel
    readonly property alias searchField: search
    readonly property alias listView: list
    spacing: panel.gaps.lg
    component Label: Text {
        textFormat: Text.PlainText
        color: root.panel.foreground
        font.family: root.panel.fontFamily
        font.pixelSize: root.panel.fonts.body
    }

    component Badge: Ui.BorderSurface {
        id: badge
        property string text: ""
        property color tint: root.panel.dim
        implicitWidth: badgeLabel.implicitWidth + Style.space(12)
        implicitHeight: badgeLabel.implicitHeight + Style.space(4)
        radius: Style.cornerRadius
        color: Util.alpha(tint, 0.16)
        border.width: 1
        border.color: Util.alpha(tint, 0.6)
        Label {
            id: badgeLabel
            anchors.centerIn: parent
            text: badge.text
            color: badge.tint
            font.pixelSize: root.panel.fonts.caption
            font.bold: true
        }
    }

    Item {
        width: parent.width
        visible: root.panel.tab !== "Overview"
        implicitHeight: Math.max(search.implicitHeight, filterGroup.implicitHeight)
        Ui.TextField {
            id: search
            objectName: "search"
            anchors.left: parent.left
            anchors.right: filterGroup.left
            anchors.rightMargin: root.panel.gaps.lg
            anchors.verticalCenter: parent.verticalCenter
            placeholderText: "Search  ( / )"
            foreground: root.panel.foreground
            // Typing breaks a plain binding, so follow resets explicitly.
            Connections {
                target: root.panel
                function onQueryChanged() {
                    if (search.text !== root.panel.query)
                        search.text = root.panel.query;
                }
            }
            onTextEdited: {
                root.panel.query = text;
                root.panel.cursor = 0;
            }
            Keys.onEscapePressed: {
                if (text !== "")
                    root.panel.query = "";
                else
                    root.panel.focusKeys();
            }
            Keys.onReturnPressed: root.panel.focusKeys()
            Keys.onEnterPressed: root.panel.focusKeys()
            Keys.onDownPressed: root.panel.focusKeys()
        }
        Ui.ButtonGroup {
            id: filterGroup
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: root.panel.gaps.sm
            focusable: false
            options: Model.filters(root.panel.tab)
            value: root.panel.filter
            foreground: root.panel.foreground
            fontSize: root.panel.fonts.bodySmall
            onChanged: function (value) {
                root.panel.filter = value;
                root.panel.cursor = 0;
            }
        }
    }

    // A partial query can retain useful rows alongside its scope-specific diagnostic.
    Label {
        objectName: "scopeWarning"
        width: parent.width
        visible: root.panel.scopeNotice !== "" && root.panel.entries.count > 0
        text: root.panel.scopeNotice
        color: root.panel.dim
        font.pixelSize: root.panel.fonts.bodySmall
        wrapMode: Text.WordWrap
        maximumLineCount: 2
        elide: Text.ElideRight
    }

    ListView {
        id: list
        width: parent.width
        height: Math.min(contentHeight, Style.space(376))
        visible: root.panel.entries.count > 0
        clip: true
        model: root.panel.entries
        spacing: Style.space(2)
        reuseItems: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        QQC.ScrollBar.vertical: QQC.ScrollBar {
            policy: QQC.ScrollBar.AsNeeded
        }

        delegate: Ui.CursorSurface {
            id: rowItem
            required property int index
            required property string lead
            required property string title
            required property string subtitle
            required property string badge
            required property string tone
            required property string copyText
            width: list.width
            implicitHeight: Style.space(root.panel.cfg.compact ? 40 : 50)
            hasCursor: root.panel.cursor === index
            foreground: root.panel.foreground

            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onContainsMouseChanged: if (containsMouse)
                    root.panel.cursor = rowItem.index
                onClicked: root.panel.openDetail(rowItem.index)
            }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: root.panel.gaps.xl
                anchors.rightMargin: root.panel.gaps.lg
                spacing: root.panel.gaps.xl

                // Port number, or a state dot for rows that have none.
                Item {
                    Layout.preferredWidth: rowItem.lead !== "" ? leadMetrics.advanceWidth : Style.space(7)
                    Layout.fillHeight: true
                    Label {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        visible: rowItem.lead !== ""
                        text: rowItem.lead
                        font.bold: true
                    }
                    Rectangle {
                        anchors.centerIn: parent
                        visible: rowItem.lead === ""
                        width: Style.space(7)
                        height: width
                        radius: width / 2
                        color: root.panel.toneColor(rowItem.tone)
                    }
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.minimumWidth: 0
                    spacing: Style.space(1)
                    Label {
                        Layout.fillWidth: true
                        text: rowItem.title
                        elide: Text.ElideMiddle
                    }
                    Label {
                        Layout.fillWidth: true
                        text: rowItem.subtitle
                        color: root.panel.dim
                        font.pixelSize: root.panel.fonts.caption
                        elide: Text.ElideRight
                    }
                }
                Badge {
                    text: rowItem.badge
                    tint: root.panel.toneColor(rowItem.tone)
                }
                Ui.PanelActionButton {
                    // nf-md-content_copy
                    iconText: "\u{f018f}"
                    tooltipText: "Copy " + rowItem.copyText
                    foreground: root.panel.foreground
                    opacity: rowItem.hasCursor ? 1 : 0
                    enabled: rowItem.hasCursor && rowItem.copyText !== ""
                    onClicked: root.panel.hostWidget.copyText(rowItem.copyText)
                }
            }
        }
    }

    Item {
        width: parent.width
        visible: root.panel.tab !== "Overview" && root.panel.entries.count === 0
        implicitHeight: Style.space(132)
        Label {
            anchors.centerIn: parent
            width: parent.width - Style.space(48)
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            color: root.panel.dim
            objectName: "emptyState"
            text: Model.emptyText(root.panel.tab, root.panel.query, root.panel.filter, root.panel.scopeNotice, root.panel.tab === "Projects" ? root.panel.inventory.projects !== undefined : root.panel.tab === "Tools" ? root.panel.inventory.tools !== undefined : root.panel.sampled, root.panel.cfg)
        }
    }

    TextMetrics {
        id: leadMetrics
        font.family: root.panel.fontFamily
        font.pixelSize: root.panel.fonts.body
        font.bold: true
        text: "65535"
    }
}
