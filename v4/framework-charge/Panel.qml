import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import qs.Commons
import qs.Services.UI
import qs.Widgets

Item {
  id: root

  required property var pluginApi

  readonly property var main: pluginApi.mainInstance
  readonly property var status: main.status

  // Each preset owns the part of the gauge that is closer to it than to its neighbours.
  readonly property var zones: [
    { limit: 50, to: 55 },
    { limit: 60, to: 65 },
    { limit: 70, to: 75 },
    { limit: 80, to: 90 },
    { limit: 100, to: 100 }
  ]
  readonly property real pixelsPerPoint: 4.8
  readonly property real barWidth: 50 * pixelsPerPoint
  readonly property real fillHeight: 18
  readonly property real shellHeight: 24
  readonly property real leadWidth: 15 // the open end left of 50 %; half a label wide, so 50 can centre
  readonly property real shellWidth: leadWidth + barWidth + 3
  readonly property real labelWidth: 30

  property var charge: null
  readonly property var limit: status.kind === "ready" || status.kind === "applying" ? status.limit : null
  readonly property var hovered: pointer.containsMouse ? presetAt(pointer.mouseX - leadWidth) : null
  readonly property var candidate: {
    if (status.kind === "applying")
      return status.target;
    if (status.kind === "ready" && hovered !== null && hovered !== limit)
      return hovered;
    return null;
  }
  readonly property var ceiling: candidate ?? limit
  readonly property color accent: candidate === null ? Color.mOnSurface : charge !== null && candidate < charge ? Color.mError : Color.mPrimary

  // The line and the fill behind it glide to a new ceiling instead of jumping.
  // While a read hides the line, ceilingX keeps its place, so the line resumes from there.
  property real ceilingX: 0
  property bool ceilingPlaced: false
  onCeilingChanged: {
    if (ceiling === null)
      return;
    ceilingX = px(ceiling);
    ceilingPlaced = true;
  }
  Behavior on ceilingX {
    enabled: root.ceilingPlaced
    NumberAnimation {
      duration: 180
      easing.type: Easing.OutCubic
    }
  }

  readonly property real chargeX: charge === null ? 0 : Math.max(0, Math.min(barWidth, px(charge)))
  readonly property real limitX: limit === null ? 0 : px(limit)
  readonly property real cutX: ceiling === null ? barWidth : ceilingX

  property real contentPreferredWidth: shellWidth + 5 + Style.margin2L
  property real contentPreferredHeight: column.implicitHeight + Style.margin2L
  property bool allowAttach: true

  function px(percent) {
    return Math.round((percent - 50) * pixelsPerPoint);
  }

  function presetAt(x) {
    const percent = 50 + x / pixelsPerPoint;
    return zones.find(zone => percent < zone.to)?.limit ?? 100;
  }

  focus: true
  Component.onCompleted: {
    forceActiveFocus();
    main.read();
  }
  Keys.onPressed: event => {
    if (status.kind !== "ready")
      return;
    const limits = main.presets;
    if (event.key === Qt.Key_Left)
      main.choose(limits.filter(preset => preset < limit).pop() ?? limit);
    else if (event.key === Qt.Key_Right)
      main.choose(limits.find(preset => preset > limit) ?? limit);
    else if (event.key === Qt.Key_Home || event.key === Qt.Key_PageDown)
      main.choose(limits[0]);
    else if (event.key === Qt.Key_End || event.key === Qt.Key_PageUp)
      main.choose(limits[limits.length - 1]);
    else
      return;
    event.accepted = true;
  }

  FileView {
    id: capacity
    // A Framework has only BAT1; a ThinkPad has BAT0.
    path: "/sys/class/power_supply/BAT0/capacity"
    blockAllReads: true
    printErrors: false
    onLoadFailed: path = "/sys/class/power_supply/BAT1/capacity"
  }

  Timer {
    interval: 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: {
      capacity.reload();
      const percent = parseInt(capacity.text());
      root.charge = percent >= 0 && percent <= 100 ? percent : null;
    }
  }

  Connections {
    target: root.main
    function onConfirmed() {
      check.restart();
    }
  }

  ColumnLayout {
    id: column
    anchors.fill: parent
    anchors.margins: Style.marginL
    spacing: 10

    RowLayout {
      Layout.preferredWidth: root.shellWidth
      Layout.preferredHeight: 30
      spacing: 8

      NText {
        text: "🌿"
        pointSize: Style.fontSizeXL
      }

      NText {
        Layout.fillWidth: true
        text: "Charge limit"
        pointSize: Style.fontSizeL
        font.weight: Style.fontWeightSemiBold
        color: Color.mOnSurface
      }

      Item {
        Layout.preferredWidth: 18
        Layout.preferredHeight: 18

        NBusyIndicator {
          anchors.centerIn: parent
          visible: root.status.kind === "applying"
          running: visible
          size: 14
          strokeWidth: 2
        }

        NIcon {
          anchors.centerIn: parent
          visible: root.status.kind === "failed"
          icon: "alert-circle"
          color: Color.mError

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.main.read()
            onEntered: TooltipService.show(parent, root.status.message)
            onExited: TooltipService.hide(parent)
          }
        }

        NIcon {
          id: checkIcon
          anchors.centerIn: parent
          visible: root.status.kind === "ready"
          opacity: 0
          icon: "check"
          color: Color.mPrimary

          SequentialAnimation {
            id: check
            NumberAnimation {
              target: checkIcon
              property: "opacity"
              from: 0
              to: 1
              duration: 120
            }
            PauseAnimation {
              duration: 430
            }
            NumberAnimation {
              target: checkIcon
              property: "opacity"
              to: 0
              duration: 250
            }
          }
        }
      }

      NText {
        Layout.preferredWidth: 60
        horizontalAlignment: Text.AlignRight
        text: root.limit === null ? "" : root.limit + "%"
        pointSize: Style.fontSizeXXL
        font.weight: Style.fontWeightBold
        color: Color.mOnSurface

        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          onEntered: TooltipService.show(parent, "The BIOS may restore its saved limit at reboot.")
          onExited: TooltipService.hide(parent)
        }
      }
    }

    Item {
      Layout.preferredWidth: root.shellWidth + 5
      Layout.preferredHeight: root.shellHeight + 3 + 17

      // The battery is cut open left of 50 %: the outline's closed end lies
      // outside the clip, so its edges stop flush at the cut.
      Item {
        width: root.shellWidth
        height: root.shellHeight
        clip: true

        Rectangle {
          x: -10
          width: parent.width + 10
          height: parent.height
          radius: 7
          color: "transparent"
          border.color: Color.mOutline
          border.width: 1.5
        }
      }

      Rectangle {
        x: root.shellWidth + 2
        y: (root.shellHeight - height) / 2
        width: 3
        height: 10
        radius: 1.5
        color: Color.mOutline
      }

      // The bar, in bar coordinates: x = 0 is 50 %.
      Item {
        x: root.leadWidth
        y: (root.shellHeight - root.fillHeight) / 2
        width: root.barWidth
        height: root.fillHeight

        Rectangle {
          x: -root.leadWidth
          width: root.leadWidth
          height: parent.height
          visible: root.charge !== null && root.charge >= 50
          color: Color.mPrimary
        }

        Rectangle {
          width: Math.min(root.chargeX, root.cutX)
          height: parent.height
          color: Color.mPrimary
        }

        // Charge above the ceiling is what the firmware will discharge.
        Rectangle {
          x: root.cutX
          width: Math.max(0, root.chargeX - root.cutX)
          height: parent.height
          color: Color.mError
        }

        Rectangle {
          x: root.chargeX
          width: Math.max(0, Math.min(root.limitX, root.cutX) - root.chargeX)
          height: parent.height
          visible: root.limit !== null
          color: Qt.alpha(Color.mPrimary, 0.3)
        }

        Rectangle {
          x: Math.max(root.limitX, root.chargeX)
          width: Math.max(0, root.cutX - x)
          height: parent.height
          visible: root.limit !== null
          color: Qt.alpha(Color.mPrimary, 0.15)
        }

        Rectangle {
          x: Math.max(0, Math.min(root.barWidth - 1, root.ceilingX - 1))
          width: 1.5
          height: parent.height
          radius: 0.75
          visible: root.ceiling !== null
          color: root.accent
        }
      }

      // Labels sit centred under their presets; the hovered one carries the preview.
      Repeater {
        model: root.main.presets

        Rectangle {
          id: label

          required property int modelData
          readonly property bool previewed: modelData === root.candidate

          x: root.leadWidth + root.px(modelData) - width / 2
          y: root.shellHeight + 3
          width: root.labelWidth
          height: 17
          radius: 5
          color: previewed ? Qt.alpha(root.accent, 0.15) : "transparent"

          NText {
            anchors.centerIn: parent
            text: label.modelData + (label.previewed ? "%" : "")
            pointSize: Style.fontSizeS
            font.weight: label.previewed || label.modelData === root.limit ? Style.fontWeightBold : Style.fontWeightMedium
            color: label.previewed ? root.accent : label.modelData === root.limit ? Color.mOnSurface : Qt.alpha(Color.mOnSurfaceVariant, 0.6)
          }
        }
      }

      MouseArea {
        id: pointer
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: root.status.kind === "ready" ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: root.main.choose(root.presetAt(mouseX - root.leadWidth))
      }
    }
  }
}
