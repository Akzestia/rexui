// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: MIT
const javascript = require('tree-sitter-javascript/grammar');

module.exports = grammar(javascript, {
  name: 'rui',

  conflicts: ($, previous) => previous.concat([
    [$.primary_expression, $.qualified_type],
    [$.qualified_name, $.qualified_type],
  ]),

  rules: {
    program: $ => seq(
      repeat(choice($.import_line, $.use_declaration)),
      $.element,
    ),

    import_line: $ => seq('import', field('source', alias(/[^\n]*/, $.import_source))),

    use_declaration: $ => seq(
      'use',
      field('source', $.string),
      optional(seq('as', field('alias', alias($.identifier, $.namespace_identifier)))),
    ),

    element: $ => seq(
      field('type', choice(alias($.identifier, $.type_identifier), $.qualified_type)),
      field('body', $.element_body),
    ),

    qualified_type: $ => seq(
      alias($.identifier, $.namespace_identifier),
      repeat(seq('.', alias($.identifier, $.namespace_identifier))),
      '.',
      alias($.identifier, $.type_identifier),
    ),

    element_body: $ => seq(
      '{',
      repeat(choice(
        $.element,
        $.id_binding,
        $.binding,
        $.property_declaration,
        $.signal_declaration,
        $.function_declaration,
        ';',
        ',',
      )),
      '}',
    ),

    id_binding: $ => prec.right(seq(
      'id', ':',
      field('value', $.identifier),
      optional($._semicolon),
    )),

    binding: $ => seq(
      field('name', choice(alias($.identifier, $.property_identifier), alias('signal', $.property_identifier), $.qualified_name)),
      ':',
      field('value', $._value),
    ),

    qualified_name: $ => seq(
      $.identifier,
      repeat1(seq('.', alias($.identifier, $.property_identifier))),
    ),

    signal_declaration: $ => prec.right(seq(
      'signal',
      field('name', alias($.identifier, $.property_identifier)),
      optional(field('parameters', $.signal_parameters)),
    )),
    signal_parameters: $ => seq('(', optional(seq($.signal_parameter, repeat(seq(',', $.signal_parameter)))), ')'),
    signal_parameter: $ => seq(optional(field('type', alias($.identifier, $.type_identifier))), field('name', $.identifier)),

    property_declaration: $ => seq(
      optional('readonly'),
      'property',
      optional(field('type', alias(choice($.identifier, 'var'), $.type_identifier))),
      field('name', alias($.identifier, $.property_identifier)),
      choice(
        seq(':', field('value', $._value)),
        $._semicolon,
      ),
    ),

    _value: $ => choice(
      $.element,
      $.expression_statement,
      $.statement_block,
      $.if_statement,
      $.switch_statement,
      $.for_statement,
      $.for_in_statement,
      $.while_statement,
      $.do_statement,
      $.try_statement,
      $.throw_statement,
      $.return_statement,
    ),
  },
});
