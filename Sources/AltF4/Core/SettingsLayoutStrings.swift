// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AltF4 contributors

import Foundation

/// Generic titles that split a long Settings page into short groups, so a
/// page never needs its own copy just to name a group of rows.
struct SettingsLayoutStrings {
    let moreOptions: String
    let behavior: String
    let appearance: String
    let shortcuts: String
    let whatToShow: String
    let privacy: String
    let advanced: String
}

extension FeatureStrings {
    static func settingsLayout(_ language: AppLanguage) -> SettingsLayoutStrings {
        switch language {
        case .enUS: return SettingsLayoutStrings(
            moreOptions: "More options",
            behavior: "Behavior",
            appearance: "Appearance",
            shortcuts: "Shortcuts",
            whatToShow: "What to show",
            privacy: "Privacy",
            advanced: "Advanced")
        case .ptBR: return SettingsLayoutStrings(
            moreOptions: "Mais opções",
            behavior: "Comportamento",
            appearance: "Aparência",
            shortcuts: "Atalhos",
            whatToShow: "O que mostrar",
            privacy: "Privacidade",
            advanced: "Avançado")
        case .tr: return SettingsLayoutStrings(
            moreOptions: "Diğer seçenekler",
            behavior: "Davranış",
            appearance: "Görünüm",
            shortcuts: "Kısayollar",
            whatToShow: "Neler gösterilsin",
            privacy: "Gizlilik",
            advanced: "Gelişmiş")
        case .ru: return SettingsLayoutStrings(
            moreOptions: "Другие параметры",
            behavior: "Поведение",
            appearance: "Оформление",
            shortcuts: "Сочетания клавиш",
            whatToShow: "Что показывать",
            privacy: "Конфиденциальность",
            advanced: "Дополнительно")
        case .es: return SettingsLayoutStrings(
            moreOptions: "Más opciones",
            behavior: "Comportamiento",
            appearance: "Apariencia",
            shortcuts: "Atajos",
            whatToShow: "Qué mostrar",
            privacy: "Privacidad",
            advanced: "Avanzado")
        case .de: return SettingsLayoutStrings(
            moreOptions: "Weitere Optionen",
            behavior: "Verhalten",
            appearance: "Erscheinungsbild",
            shortcuts: "Tastenkurzbefehle",
            whatToShow: "Was angezeigt wird",
            privacy: "Datenschutz",
            advanced: "Erweitert")
        case .fr: return SettingsLayoutStrings(
            moreOptions: "Plus d’options",
            behavior: "Comportement",
            appearance: "Apparence",
            shortcuts: "Raccourcis",
            whatToShow: "Éléments affichés",
            privacy: "Confidentialité",
            advanced: "Avancé")
        case .it: return SettingsLayoutStrings(
            moreOptions: "Altre opzioni",
            behavior: "Comportamento",
            appearance: "Aspetto",
            shortcuts: "Scorciatoie",
            whatToShow: "Cosa mostrare",
            privacy: "Privacy",
            advanced: "Avanzate")
        case .ja: return SettingsLayoutStrings(
            moreOptions: "その他のオプション",
            behavior: "動作",
            appearance: "外観",
            shortcuts: "ショートカット",
            whatToShow: "表示する項目",
            privacy: "プライバシー",
            advanced: "詳細")
        case .ko: return SettingsLayoutStrings(
            moreOptions: "추가 옵션",
            behavior: "동작",
            appearance: "모양",
            shortcuts: "단축키",
            whatToShow: "표시할 항목",
            privacy: "개인정보 보호",
            advanced: "고급")
        case .zhHans: return SettingsLayoutStrings(
            moreOptions: "更多选项",
            behavior: "行为",
            appearance: "外观",
            shortcuts: "快捷键",
            whatToShow: "显示内容",
            privacy: "隐私",
            advanced: "高级")
        case .zhTW: return SettingsLayoutStrings(
            moreOptions: "更多選項",
            behavior: "行為",
            appearance: "外觀",
            shortcuts: "快速鍵",
            whatToShow: "顯示內容",
            privacy: "隱私權",
            advanced: "進階")
        case .zhHK: return SettingsLayoutStrings(
            moreOptions: "更多選項",
            behavior: "行為",
            appearance: "外觀",
            shortcuts: "快速鍵",
            whatToShow: "顯示內容",
            privacy: "私隱",
            advanced: "進階")
        }
    }
}
