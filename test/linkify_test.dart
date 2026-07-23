import 'package:flutter_test/flutter_test.dart';
import 'package:ircmobileapp/linkify.dart';
import 'package:linkify/linkify.dart';

// goguma's _UrlLinkifier doesn't set custom text content.
UrlElement urlElement(String url) {
  return UrlElement(url, url);
}

void main() {
  test('Parses only text', () {
    expect(
      extractLinks('Lorem ipsum dolor sit amet'),
      [TextElement('Lorem ipsum dolor sit amet')],
    );
  });

  test('Parses only link', () {
    expect(
      extractLinks('https://example.com'),
      [urlElement('https://example.com')],
    );
  });

  test('Parses only links with space', () {
    expect(
      extractLinks('https://example.com https://emersion.fr'),
      [
        urlElement('https://example.com'),
        TextElement(' '),
        urlElement('https://emersion.fr'),
      ],
    );
  });

  test('Parses links with text', () {
    expect(
      extractLinks(
          'Lorem ipsum dolor sit amet https://example.com https://emersion.fr'),
      [
        TextElement('Lorem ipsum dolor sit amet '),
        urlElement('https://example.com'),
        TextElement(' '),
        urlElement('https://emersion.fr'),
      ],
    );
  });

  test('Parses links with text with newlines', () {
    expect(
      extractLinks(
          'https://emersion.fr\nLorem ipsum\ndolor sit amet\nhttps://example.com'),
      [
        urlElement('https://emersion.fr'),
        TextElement('\nLorem ipsum\ndolor sit amet\n'),
        urlElement('https://example.com'),
      ],
    );
  });

  test('Parse multiple links', () {
    expect(
      extractLinks(
          'ircs://example.org/#itworks has a website: https://example.org/itworks'),
      [
        urlElement('ircs://example.org/#itworks'),
        TextElement(' has a website: '),
        urlElement('https://example.org/itworks'),
      ],
    );
  });

  test('Parse webarchive link', () {
    expect(
      extractLinks(
          'https://web.archive.org/web/19990125095658/http://www.emersion.fr/'),
      [
        urlElement(
            'https://web.archive.org/web/19990125095658/http://www.emersion.fr/'),
      ],
    );
  });
}
