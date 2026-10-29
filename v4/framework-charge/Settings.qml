import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Widgets

// The charge planner's settings. The settings popup calls saveSettings() on Apply; Main plans
// again when pluginSettings changes.
ColumnLayout {
  id: root

  property var pluginApi: null
  readonly property var settings: pluginApi.pluginSettings
  readonly property var limits: [50, 60, 70, 80, 100].map(limit => ({ "key": String(limit), "name": limit + " %" }))

  property bool workHours: settings.workHours
  property string workDays: settings.workDays
  property string workLimit: String(settings.workLimit)
  property string afterWorkLimit: String(settings.afterWorkLimit)
  property bool learnRates: settings.learnRates

  spacing: Style.marginM

  function saveSettings() {
    Object.assign(pluginApi.pluginSettings, {
      "workHours": workHours,
      "workDays": workDays,
      "workStart": workStart.text.trim(),
      "workEnd": workEnd.text.trim(),
      "workLimit": Number(workLimit),
      "afterWorkLimit": Number(afterWorkLimit),
      "tolerance": tolerance.value,
      "learnRates": learnRates
    });
    pluginApi.saveSettings();
  }

  NToggle {
    Layout.fillWidth: true
    label: "Working hours"
    description: "Hold one limit while you work, and reach another by the time work ends."
    checked: root.workHours
    onToggled: checked => root.workHours = checked
  }

  NComboBox {
    Layout.fillWidth: true
    visible: root.workHours
    label: "Work days"
    model: [
      { "key": "weekdays", "name": "Monday to Friday" },
      { "key": "monSat", "name": "Monday to Saturday" },
      { "key": "everyDay", "name": "Every day" }
    ]
    currentKey: root.workDays
    onSelected: key => root.workDays = key
  }

  NTextInput {
    id: workStart
    Layout.fillWidth: true
    visible: root.workHours
    label: "Work starts"
    description: "24-hour time, like 08:00."
    text: root.settings.workStart
  }

  NTextInput {
    id: workEnd
    Layout.fillWidth: true
    visible: root.workHours
    label: "Work ends"
    text: root.settings.workEnd
  }

  NComboBox {
    Layout.fillWidth: true
    visible: root.workHours
    label: "Limit during work"
    model: root.limits
    currentKey: root.workLimit
    onSelected: key => root.workLimit = key
  }

  NComboBox {
    Layout.fillWidth: true
    visible: root.workHours
    label: "Limit after work"
    description: "Reached by the time work ends, and kept until it starts again."
    model: root.limits
    currentKey: root.afterWorkLimit
    onSelected: key => root.afterWorkLimit = key
  }

  NSpinBox {
    id: tolerance
    Layout.fillWidth: true
    label: "Arrival tolerance (%)"
    description: "How far short of a target still counts as on time. Smaller starts charging earlier."
    from: 1
    to: 10
    value: root.settings.tolerance
  }

  NToggle {
    Layout.fillWidth: true
    label: "Learn charging speed"
    description: "Plan with the speed of your last few charges, from upower's history. Off: about 1 minute per percent below 80 %."
    checked: root.learnRates
    onToggled: checked => root.learnRates = checked
  }
}
