import QtQuick
import Quickshell
import qs.Modules.Bar.Widgets
import qs.Services.UI

// v4 cannot change what a click on its Battery widget does, so this widget
// draws that Battery widget itself and takes the left click. Right clicks and
// hover fall through to it, so its tooltip and menu still work. The Battery
// widget's options, like displayMode, come from this plugin's settings.json.
Item {
  id: root

  required property var pluginApi
  property ShellScreen screen
  property string widgetId: ""
  property string section: ""
  property int sectionWidgetIndex: -1
  property int sectionWidgetsCount: 0

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
