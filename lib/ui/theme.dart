import 'package:flutter/material.dart';
import 'package:pg_core/pg_core.dart';

/// Colors of the editor: syntax classes and what the index adds (objects by kind, problems).
@immutable
class SyntaxColors {
  const SyntaxColors({
    required this.background,
    required this.gutter,
    required this.text,
    required this.keyword,
    required this.string,
    required this.number,
    required this.comment,
    required this.liquibase,
    required this.operator,
    required this.relation,
    required this.routine,
    required this.type,
    required this.error,
    required this.warning,
    required this.link,
  });

  final Color background;
  final Color gutter;
  final Color text;
  final Color keyword;
  final Color string;
  final Color number;
  final Color comment;
  final Color liquibase;
  final Color operator;
  final Color relation;
  final Color routine;
  final Color type;
  final Color error;
  final Color warning;
  final Color link;

  static const dark = SyntaxColors(
    background: Color(0xFF1E1F22),
    gutter: Color(0xFF6F737A),
    text: Color(0xFFBCBEC4),
    keyword: Color(0xFFCF8E6D),
    string: Color(0xFF6AAB73),
    number: Color(0xFF2AACB8),
    comment: Color(0xFF7A7E85),
    liquibase: Color(0xFF5F9EA0),
    operator: Color(0xFFBCBEC4),
    relation: Color(0xFF56A8F5),
    routine: Color(0xFFE8BA36),
    type: Color(0xFFC77DBB),
    error: Color(0xFFF75464),
    warning: Color(0xFFE0A84E),
    link: Color(0xFF4E9BFF),
  );

  static const light = SyntaxColors(
    background: Color(0xFFFFFFFF),
    gutter: Color(0xFF9AA0A6),
    text: Color(0xFF1F2328),
    keyword: Color(0xFF0033B3),
    string: Color(0xFF067D17),
    number: Color(0xFF1750EB),
    comment: Color(0xFF8C8C8C),
    liquibase: Color(0xFF00737A),
    operator: Color(0xFF1F2328),
    relation: Color(0xFF00627A),
    routine: Color(0xFF7A4F00),
    type: Color(0xFF871094),
    error: Color(0xFFD32F2F),
    warning: Color(0xFFB26A00),
    link: Color(0xFF2F6FDE),
  );

  static SyntaxColors of(BuildContext context) => Theme.of(context).brightness == Brightness.dark ? dark : light;

  Color forHighlight(HighlightKind kind) => switch (kind) {
    HighlightKind.keyword => keyword,
    HighlightKind.string => string,
    HighlightKind.number => number,
    HighlightKind.comment => comment,
    HighlightKind.liquibase => liquibase,
    HighlightKind.operator || HighlightKind.punctuation => operator,
    HighlightKind.identifier => text,
  };

  Color forSpace(ObjectSpace space) => switch (space) {
    ObjectSpace.relation => relation,
    ObjectSpace.routine => routine,
    ObjectSpace.type => type,
    _ => text,
  };
}

const editorFont = 'DejaVu Sans Mono';
const editorFontFallback = ['Noto Sans Mono', 'Ubuntu Mono', 'monospace'];

IconData iconOf(ObjectKind kind) => switch (kind) {
  ObjectKind.schema => Icons.folder_special_outlined,
  ObjectKind.table => Icons.table_chart_outlined,
  ObjectKind.view || ObjectKind.materializedView => Icons.view_list_outlined,
  ObjectKind.function => Icons.functions,
  ObjectKind.procedure => Icons.play_arrow_outlined,
  ObjectKind.type || ObjectKind.domain => Icons.data_object,
  ObjectKind.sequence => Icons.format_list_numbered,
  ObjectKind.tableIndex => Icons.bolt_outlined,
  ObjectKind.trigger => Icons.flash_on_outlined,
  ObjectKind.extension => Icons.extension_outlined,
};
