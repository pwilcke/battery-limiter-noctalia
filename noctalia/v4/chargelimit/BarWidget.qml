import QtQuick
import Quickshell
import qs.Modules.Bar.Widgets
import qs.Services.UI

// v4 cannot change what a click on its Battery widget does, so this widget
// draws that Battery widget itself and takes the left click. Right clicks and
// hover fall through to it, so its tooltip and menu still work. The Battery
// widget's options, like displayMode, come from this plugin's settings.json.
// While the battery charges or drains, the pill reads "49% → 70%", as the panel does.
Item {
  id: root

  required property var pluginApi
  property ShellScreen screen
  property string widgetId: ""
  property string section: ""
  property int sectionWidgetIndex: -1
  property int sectionWidgetsCount: 0

  readonly property var main: pluginApi.mainInstance
  readonly property string suffix: {
    const status = main ? main.status : null;
    const limit = status && (status.kind === "ready" || status.kind === "applying") ? status.limit : null;
    const moving = main !== null && main.charge !== limit && (main.activity === "charging" || main.activity === "draining");
    return limit !== null && moving ? "% → " + limit + "%" : "%";
  }

  implicitWidth: battery.implicitWidth
  implicitHeight: battery.implicitHeight

  Battery {
    id: battery
    anchors.fill: parent
    screen: root.screen
    widgetId: "Battery"
    widgetSettings: root.pluginApi.pluginSettings
    section: root.section
    sectionWidgetIndex: root.sectionWidgetIndex
    sectionWidgetsCount: root.sectionWidgetsCount

    // The Battery widget's pill has no id we can reach, so it is found as the child that has a
    // suffix. Only the icon modes draw it; the graphic modes keep their own percentage.
    Component.onCompleted: {
      const pill = Array.from(children).find(child => child.suffix !== undefined);
      if (pill === undefined)
        throw new Error("Noctalia's Battery widget has no pill with a suffix; its layout changed.");
      pill.suffix = Qt.binding(() => root.suffix);
    }
  }

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton
    cursorShape: Qt.PointingHandCursor
    onClicked: {
      TooltipService.hide();
      root.pluginApi.togglePanel(root.screen, root);
    }
  }
}
