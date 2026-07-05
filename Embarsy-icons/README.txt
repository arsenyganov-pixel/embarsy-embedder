EMBARSY — иконки macOS

AppIcon/
  Embarsy.iconset/   — готовый iconset. Собрать .icns:  iconutil -c icns Embarsy.iconset
  Embarsy_1024.png   — мастер PNG
  Embarsy_AppIcon.svg — вектор (фон Snow + знак)

Toolbar/
  EmbarsyIndex_Template.svg — template-знак (чёрный, прозрачный фон), источник
    истины для векторной марки. Приложение рисует знак нативно из этого контура
    (native/EmbarsyApp/Sources/EmbarsyMark.swift) и тинтит по статусу, поэтому
    растровые PNG-экспорты (template/ on_accent/ off_gray/) больше не нужны и удалены.

Знак: Vector Ears (узкий наконечник 22°), по центру. Фон приложения: Snow.