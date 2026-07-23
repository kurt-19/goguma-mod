import 'package:flutter/rendering.dart';

/// Strip ANSI formatting as defined in:
/// https://modern.ircdocs.horse/formatting.html
String stripAnsiFormatting(String s) {
  var out = '';
  for (var i = 0; i < s.length; i++) {
    var ch = s[i];
    switch (ch) {
      case '\x02': // bold
      case '\x1D': // italic
      case '\x1F': // underline
      case '\x1E': // strike-through
      case '\x11': // monospace
      case '\x16': // reverse color
      case '\x0F': // reset
        break; // skip
      case '\x03': // color
        if (i + 1 >= s.length || !_isDigit(s[i + 1])) {
          break;
        }
        i++;
        if (i + 1 < s.length && _isDigit(s[i + 1])) {
          i++;
        }
        if (i + 2 < s.length && s[i + 1] == ',' && _isDigit(s[i + 2])) {
          i += 2;
          if (i + 1 < s.length && _isDigit(s[i + 1])) {
            i++;
          }
        }
        break;
      case '\x04': // hex color
        var color = _parseHexColorCode(s.substring(i + 1));
        if (color == null) {
          break;
        }
        i += 6;
        if (s.length > i + 1 && s[i + 1] == ',') {
          var color = _parseHexColorCode(s.substring(i + 2));
          if (color != null) {
            i += 7;
          }
        }
        break;
      default:
        out += ch;
    }
  }
  return out;
}

const _colorHexCodes = [
  0xffffffff,
  0xff000000,
  0xff00007f,
  0xff009300,
  0xffff0000,
  0xff7f0000,
  0xff9c009c,
  0xfffc7f00,
  0xffffff00,
  0xff00fc00,
  0xff009393,
  0xff00ffff,
  0xff0000fc,
  0xffff00ff,
  0xff7f7f7f,
  0xffd2d2d2,
  0xff470000,
  0xff472100,
  0xff474700,
  0xff324700,
  0xff004732,
  0xff00472c,
  0xff004747,
  0xff002747,
  0xff000047,
  0xff2e0047,
  0xff470047,
  0xff47002a,
  0xff740000,
  0xff743a00,
  0xff747400,
  0xff517400,
  0xff007400,
  0xff007449,
  0xff007474,
  0xff004074,
  0xff000074,
  0xff4b0074,
  0xff740074,
  0xff740045,
  0xffb50000,
  0xffb56300,
  0xffb5b500,
  0xff7db500,
  0xff00b500,
  0xff00b573,
  0xff00b5b5,
  0xff0063b5,
  0xff0000b5,
  0xff7500b5,
  0xffb500b5,
  0xffb5006b,
  0xffff0000,
  0xffff9200,
  0xffffff00,
  0xffb9ff00,
  0xff00ff00,
  0xff00ffa8,
  0xff00ffff,
  0xff009bff,
  0xff0000ff,
  0xffad00ff,
  0xffff00ff,
  0xffff0092,
  0xffff6666,
  0xffffb466,
  0xffffff66,
  0xffccff66,
  0xff66ff66,
  0xff66ffb4,
  0xff66ffff,
  0xff66b4ff,
  0xff6666ff,
  0xffcc66ff,
  0xffff66ff,
  0xffff66b4,
  0xffffb4b4,
  0xffffdeb4,
  0xffffffb4,
  0xffe6ffb4,
  0xffb4ffb4,
  0xffb4ffe6,
  0xffb4ffff,
  0xffb4deff,
  0xffb4b4ff,
  0xffdeb4ff,
  0xffffb4ff,
  0xffffb4de,
  0xff000000,
  0xff141414,
  0xff282828,
  0xff3c3c3c,
  0xff505050,
  0xff646464,
  0xff787878,
  0xff8c8c8c,
  0xffa0a0a0,
  0xffb4b4b4,
  0xffc8c8c8,
];

/// Apply ANSI formatting as defined in:
/// https://modern.ircdocs.horse/formatting.html
List<TextSpan> applyAnsiFormatting(String s, TextStyle base) {
  var current = StringBuffer();
  List<TextSpan> spans = [];
  var bold = false;
  var italic = false;
  var underline = false;
  var strikeThrough = false;
  var monospace = false;
  var reverse = false;
  Color? fgColor;
  Color? bgColor;
  for (var i = 0; i <= s.length; i++) {
    var ch = i == s.length ? '\x0F' : s[i];
    switch (ch) {
      case '\x0F': // reset
      case '\x02': // bold
      case '\x1D': // italic
      case '\x1F': // underline
      case '\x1E': // strike-through
      case '\x11': // monospace
      case '\x16': // reverse color
      case '\x03': // color
      case '\x04': // hex color
        List<TextDecoration> decorations = [
          base.decoration ?? TextDecoration.none
        ];
        if (underline) {
          decorations.add(TextDecoration.underline);
        }
        if (strikeThrough) {
          decorations.add(TextDecoration.lineThrough);
        }
        var textColor = reverse ? bgColor : fgColor;
        var backgroundColor = reverse ? fgColor : bgColor;
        spans.add(TextSpan(
            text: current.toString(),
            style: base.copyWith(
              fontWeight: bold ? FontWeight.bold : null,
              fontStyle: italic ? FontStyle.italic : null,
              decoration: TextDecoration.combine(decorations),
              color: textColor,
              backgroundColor: backgroundColor,
              fontFamily: monospace ? 'monospace' : null,
            )));
        current.clear();
    }
    if (i == s.length) {
      break;
    }
    switch (ch) {
      case '\x0F': // reset
        bold = false;
        italic = false;
        underline = false;
        strikeThrough = false;
        monospace = false;
        reverse = false;
        fgColor = null;
        bgColor = null;
        break;
      case '\x02': // bold
        bold = !bold;
        break;
      case '\x1D': // italic
        italic = !italic;
        break;
      case '\x1F': // underline
        underline = !underline;
        break;
      case '\x1E': // strike-through
        strikeThrough = !strikeThrough;
        break;
      case '\x11': // monospace
        monospace = !monospace;
        break;
      case '\x03': // color
        if (i + 1 >= s.length || !_isDigit(s[i + 1])) {
          fgColor = null;
          bgColor = null;
          break;
        }
        i++;
        var fg = s[i].codeUnits[0] - '0'.codeUnits[0];
        if (i + 1 < s.length && _isDigit(s[i + 1])) {
          i++;
          fg *= 10;
          fg += s[i].codeUnits[0] - '0'.codeUnits[0];
        }
        fgColor = _ircColor(fg);
        if (i + 2 < s.length && s[i + 1] == ',' && _isDigit(s[i + 2])) {
          i += 2;
          var bg = s[i].codeUnits[0] - '0'.codeUnits[0];
          if (i + 1 < s.length && _isDigit(s[i + 1])) {
            i++;
            bg *= 10;
            bg += s[i].codeUnits[0] - '0'.codeUnits[0];
          }
          bgColor = _ircColor(bg);
        }
        break;
      case '\x04': // hex color
        fgColor = _parseHexColorCode(s.substring(i + 1));
        if (fgColor == null) {
          bgColor = null;
          break;
        }
        i += 6;
        if (s.length > i + 1 && s[i + 1] == ',') {
          var color = _parseHexColorCode(s.substring(i + 2));
          if (color != null) {
            bgColor = color;
            i += 7;
          }
        }
        break;
      case '\x16': // reverse color
        reverse = !reverse;
        break;
      default:
        current.write(ch);
    }
  }
  return spans;
}

bool _isDigit(String ch) {
  return '0'.codeUnits.first <= ch.codeUnits.first &&
      ch.codeUnits.first <= '9'.codeUnits.first;
}

Color? _ircColor(int code) {
  if (code == 99 || code < 0 || code >= _colorHexCodes.length) {
    return null;
  }
  return Color(_colorHexCodes[code]);
}

Color? _parseHexColorCode(String s) {
  if (s.length < 6) {
    return null;
  }
  s = s.substring(0, 6);
  if (s[0] == '+' || s[0] == '-') {
    // disallow color codes starting with a sign
    return null;
  }
  var color = int.tryParse(s, radix: 16);
  if (color == null) {
    return null;
  }
  return Color(color | 0xFF000000);
}
