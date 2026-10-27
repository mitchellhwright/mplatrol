/// [value] escaped for a single-quoted JavaScript string literal.
///
/// Escapes the backslash, the single quote, and every line terminator
/// (including U+2028/U+2029, which JavaScript parses as line breaks) that would
/// otherwise end the literal, so it is safe for arbitrary input such as passwords.
String jsEscape(String value) => value
    .replaceAll(r'\', r'\\')
    .replaceAll("'", r"\'")
    .replaceAll('\n', r'\n')
    .replaceAll('\r', r'\r')
    .replaceAll(String.fromCharCode(0x2028), '\\u2028')
    .replaceAll(String.fromCharCode(0x2029), '\\u2029');
