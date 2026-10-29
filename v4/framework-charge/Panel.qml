import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Services.UI
import qs.Widgets
import "planner.js" as Planner

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

  readonly property var charge: main.charge
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
  readonly property bool drains: (status.kind === "ready" || status.kind === "applying") && status.drains
  readonly property color accent: candidate === null ? Color.mOnSurface : drains && charge !== null && candidate < charge ? Color.mError : Color.mPrimary

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
  readonly property real drainX: drains ? cutX : barWidth

  // The presets a "charge by" target can use: only above the current limit, so it never drains.
  readonly property var choices: limit === null ? [] : main.presets.filter(preset => preset > limit)
  // The "charge by" editor: { limit, suggested, deadline }, with deadline from deadlineFor.
  property var editing: null
  // The limit may have moved since the editor opened: keep its target above it, or close it.
  onChoicesChanged: {
    if (editing !== null && !choices.includes(editing.limit))
      editing = choices.length > 0 ? Object.assign({}, editing, { "limit": choices[0] }) : null;
  }

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

  function openEditor() {
    const now = Date.now();
    const suggested = now - now % 60000 + 90 * 60000;
    editing = { "limit": choices.includes(80) ? 80 : choices[0], "suggested": suggested, "deadline": suggested };
    deadlineInput.text = "";
    deadlineInput.inputItem.forceActiveFocus();
  }

  function closeEditor() {
    editing = null;
    forceActiveFocus();
  }

  // An empty field stands for the suggestion. null while the time is invalid, or once the
  // suggestion has passed.
  function deadlineFor(text) {
    const now = Date.now();
    if (text.trim() === "")
      return editing.suggested > now ? editing.suggested : null;
    const minute = Planner.parseClock(text);
    return minute === null ? null : Planner.upcoming(now, minute);
  }

  // The time is read again on start: a typed time may have passed while the editor was open, and
  // then means another day. That day is shown first instead of started unseen.
  function startTarget() {
    const deadline = deadlineFor(deadlineInput.text);
    if (deadline !== editing.deadline) {
      editing = Object.assign({}, editing, { "deadline": deadline });
      return;
    }
    if (deadline === null || status.kind !== "ready")
      return;
    main.chargeBy(editing.limit, deadline);
    closeEditor();
  }

  function stepTarget(step) {
    const at = choices.indexOf(editing.limit);
    if (at < 0)
      throw new Error("The editor's target " + editing.limit + " is not one of its choices.");
    editing = Object.assign({}, editing, { "limit": choices[Math.max(0, Math.min(choices.length - 1, at + step))] });
  }

  focus: true
  // A running read or write brings a fresh answer anyway.
  Component.onCompleted: {
    forceActiveFocus();
    if (main.status.kind !== "reading" && main.status.kind !== "applying")
      main.read();
  }
  Keys.onPressed: event => {
    // A focused text field accepts the keys it uses, but not Up and Down, which step the editor's
    // target. The other keys must not change the limit while the editor is open.
    if (editing !== null) {
      if (event.key === Qt.Key_Up || event.key === Qt.Key_Down) {
        stepTarget(event.key === Qt.Key_Up ? 1 : -1);
        event.accepted = true;
      }
      return;
    }
    if (status.kind !== "ready")
      return;
    const limits = main.presets;
    let next = null;
    if (event.key === Qt.Key_Left)
      next = limits.filter(preset => preset < limit).pop() ?? null;
    else if (event.key === Qt.Key_Right)
      next = limits.find(preset => preset > limit) ?? null;
    else if (event.key === Qt.Key_Home || event.key === Qt.Key_PageDown)
      next = limits[0];
    else if (event.key === Qt.Key_End || event.key === Qt.Key_PageUp)
      next = limits[limits.length - 1];
    else
      return;
    // With a schedule or a target running, choosing the current limit is a manual choice, so
    // Left at the lowest preset must not choose it again.
    if (next !== null)
      main.choose(next);
    event.accepted = true;
  }

  Timer {
    interval: 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.main.sense()
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
        text: "Charge limit"
        pointSize: Style.fontSizeL
        font.weight: Style.fontWeightSemiBold
        color: Color.mOnSurface
      }

      // The settings popup only gets the keyboard once the panel lets it go.
      NIconButton {
        icon: "settings"
        tooltipText: "Settings"
        baseSize: 22
        onClicked: {
          const api = root.pluginApi;
          const screen = api.panelOpenScreen;
          api.closePanel(screen);
          BarService.openPluginSettings(screen, api.manifest);
        }
      }

      Item {
        Layout.fillWidth: true
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
          width: Math.min(root.chargeX, root.drainX)
          height: parent.height
          color: Color.mPrimary
        }

        // Charge above the ceiling is what the firmware will discharge.
        Rectangle {
          x: root.drainX
          width: Math.max(0, root.chargeX - root.drainX)
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

    // The footer: the plan with its controls, or the editor for "charge by".
    Item {
      Layout.preferredWidth: root.shellWidth + 5
      Layout.preferredHeight: 24

      RowLayout {
        anchors.fill: parent
        spacing: 6
        visible: root.editing !== null

        NIcon {
          icon: "clock"
          color: Color.mPrimary
        }

        NText {
          text: root.editing === null ? "" : root.editing.limit + "%"
          pointSize: Style.fontSizeS
          font.weight: Style.fontWeightMedium
          color: Color.mOnSurface

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            // Cycles through the choices; Up and Down step without wrapping.
            onClicked: {
              const choices = root.choices;
              root.editing = Object.assign({}, root.editing, { "limit": choices[(choices.indexOf(root.editing.limit) + 1) % choices.length] });
            }
            onEntered: TooltipService.show(parent, "Change the target (Up/Down)")
            onExited: TooltipService.hide(parent)
          }
        }

        NText {
          text: "by"
          pointSize: Style.fontSizeS
          font.weight: Style.fontWeightMedium
          color: Color.mOnSurfaceVariant
        }

        // The field starts empty so typing replaces the suggestion: a seeded value would leave
        // the caret behind it.
        NTextInput {
          id: deadlineInput
          Layout.preferredWidth: 70
          minimumInputWidth: 70
          showClearButton: false
          placeholderText: root.editing === null ? "" : Planner.clock(root.editing.suggested, root.editing.suggested)
          onTextChanged: {
            if (root.editing !== null)
              root.editing = Object.assign({}, root.editing, { "deadline": root.deadlineFor(text) });
          }
          onAccepted: root.startTarget()
        }

        NText {
          text: root.editing !== null && root.editing.deadline !== null && Planner.day(root.editing.deadline) !== Planner.day(Date.now()) ? "tomorrow" : ""
          pointSize: Style.fontSizeS
          font.weight: Style.fontWeightMedium
          color: Color.mOnSurfaceVariant
        }

        Item {
          Layout.fillWidth: true
        }

        NIconButton {
          icon: "check"
          tooltipText: "Start"
          baseSize: 22
          enabled: root.editing !== null && root.editing.deadline !== null && root.status.kind === "ready"
          onClicked: root.startTarget()
        }

        NIconButton {
          icon: "x"
          tooltipText: "Close"
          baseSize: 22
          onClicked: root.closeEditor()
        }
      }

      RowLayout {
        readonly property bool targeting: root.main.plan.target !== null

        anchors.fill: parent
        spacing: 6
        visible: root.editing === null && (targeting || root.main.plan.note !== null)

        NIcon {
          icon: parent.targeting ? "clock" : "briefcase"
          color: parent.targeting ? Color.mPrimary : Color.mOnSurfaceVariant
        }

        NText {
          Layout.fillWidth: true
          text: root.main.plan.note ?? ""
          pointSize: Style.fontSizeS
          font.weight: Style.fontWeightMedium
          color: parent.targeting ? Color.mOnSurface : Color.mOnSurfaceVariant
          elide: Text.ElideRight
        }

        NIconButton {
          visible: parent.targeting
          icon: "x"
          tooltipText: "Cancel"
          baseSize: 22
          onClicked: root.main.cancelTarget()
        }

        NIconButton {
          visible: !parent.targeting && root.main.plan.overridden
          icon: "arrow-back-up"
          tooltipText: "Back on schedule"
          baseSize: 22
          onClicked: root.main.backOnSchedule()
        }

        NIconButton {
          visible: !parent.targeting && root.choices.length > 0
          icon: "clock"
          tooltipText: "Charge by a time"
          baseSize: 22
          onClicked: root.openEditor()
        }
      }

      Item {
        anchors.fill: parent
        visible: root.editing === null && root.main.plan.target === null && root.main.plan.note === null && root.choices.length > 0

        RowLayout {
          anchors.verticalCenter: parent.verticalCenter
          spacing: 7

          NIcon {
            icon: "clock"
            color: Color.mOnSurfaceVariant
          }

          NText {
            text: "Charge by a time"
            pointSize: Style.fontSizeS
            font.weight: Style.fontWeightMedium
            color: Color.mOnSurfaceVariant
          }
        }

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: root.openEditor()
        }
      }
    }
  }
}
