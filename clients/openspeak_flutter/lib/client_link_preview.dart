import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'openspeak_api.dart';

String? firstPreviewableUrl(String body) {
  final matches = previewableUrlMatches(body);
  if (matches.isEmpty) return null;
  return matches.first.url;
}

List<PreviewableUrlMatch> previewableUrlMatches(String body) {
  final matches = <PreviewableUrlMatch>[];
  final regexp = RegExp(
    r'''(?:https?://|www\.)[^\s<>"']+''',
    caseSensitive: false,
  );
  for (final match in regexp.allMatches(body)) {
    final text = match.group(0) ?? '';
    final normalized = normalizePreviewableUrl(text);
    if (normalized == null) continue;
    var end = match.end;
    final trimmedText = _trimUrlTrailingPunctuation(text);
    if (trimmedText.length < text.length) {
      end -= text.length - trimmedText.length;
    }
    matches.add(
      PreviewableUrlMatch(
        start: match.start,
        end: end,
        text: body.substring(match.start, end),
        url: normalized,
      ),
    );
  }
  return matches;
}

String? normalizePreviewableUrl(String value) {
  value = _trimUrlTrailingPunctuation(value);
  if (value.toLowerCase().startsWith('www.')) {
    value = 'https://$value';
  }
  final uri = Uri.tryParse(value);
  if (uri == null || !uri.hasScheme || !uri.hasAuthority) return null;
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return null;
  final host = uri.host.toLowerCase();
  if (host == 'localhost' ||
      host.endsWith('.localhost') ||
      host == '127.0.0.1' ||
      host == '0.0.0.0' ||
      host == '::1') {
    return null;
  }
  return value;
}

String _trimUrlTrailingPunctuation(String value) {
  while (value.isNotEmpty &&
      '.,;:!?)，。；：！？）'.contains(value[value.length - 1])) {
    value = value.substring(0, value.length - 1);
  }
  return value;
}

class PreviewableUrlMatch {
  const PreviewableUrlMatch({
    required this.start,
    required this.end,
    required this.text,
    required this.url,
  });

  final int start;
  final int end;
  final String text;
  final String url;
}

LinkPreview fallbackLinkPreview(String url) {
  final uri = Uri.tryParse(url);
  final domain = uri?.host.isNotEmpty == true ? uri!.host : url;
  final preview = LinkPreview(
    url: url,
    domain: domain,
    title: domain,
    description: '',
    imageUrl: faviconPreviewUrl(domain),
  );
  return knownSiteFallback(preview);
}

Future<LinkPreview> fetchClientLinkPreview(String url) async {
  final fallback = fallbackLinkPreview(url);
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    final request = await client.getUrl(Uri.parse(url));
    request.followRedirects = true;
    request.maxRedirects = 5;
    request.headers.set(
      HttpHeaders.userAgentHeader,
      'Mozilla/5.0 (compatible; OpenSpeakLinkPreview/1.0)',
    );
    request.headers.set(
      HttpHeaders.acceptHeader,
      'text/html,application/xhtml+xml;q=0.9,*/*;q=0.1',
    );
    request.headers.set(
      HttpHeaders.acceptLanguageHeader,
      'zh-CN,zh;q=0.9,en;q=0.8',
    );
    final response = await request.close().timeout(const Duration(seconds: 5));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.drain<void>();
      return fallback;
    }
    final bodyBytes = await readLimitedBytes(
      response,
      2 * 1024 * 1024,
    ).timeout(const Duration(seconds: 5));
    final charset = charsetFromContentType(
      response.headers.contentType?.charset,
    );
    final html = charset.decode(bodyBytes);
    final parsed = parseLinkPreviewHtml(
      html,
      response.redirects.isEmpty
          ? Uri.parse(url)
          : response.redirects.last.location,
    );
    return mergeLinkPreview(parsed, fallback);
  } catch (_) {
    return fallback;
  } finally {
    client.close(force: true);
  }
}

Encoding charsetFromContentType(String? charset) {
  final value = charset?.trim().toLowerCase();
  if (value == 'utf-8' || value == 'utf8' || value == null || value.isEmpty) {
    return utf8;
  }
  return utf8;
}

Future<Uint8List> readLimitedBytes(Stream<List<int>> stream, int limit) async {
  final builder = BytesBuilder(copy: false);
  var total = 0;
  await for (final chunk in stream) {
    final remaining = limit - total;
    if (remaining <= 0) break;
    if (chunk.length <= remaining) {
      builder.add(chunk);
      total += chunk.length;
    } else {
      builder.add(chunk.sublist(0, remaining));
      break;
    }
  }
  return builder.takeBytes();
}

final linkTitleTagPattern = RegExp(
  r'<title[^>]*>(.*?)</title>',
  caseSensitive: false,
  dotAll: true,
);
final linkMetaTagPattern = RegExp(
  r'<meta\s+[^>]*>',
  caseSensitive: false,
  dotAll: true,
);
final linkAttrPattern = RegExp(
  r'''([a-zA-Z_:.-]+)\s*=\s*("([^"]*)"|'([^']*)'|([^\s"'>/]+))''',
  caseSensitive: false,
  dotAll: true,
);
final linkSpacePattern = RegExp(r'\s+');

LinkPreview parseLinkPreviewHtml(String html, Uri baseUri) {
  final meta = <String, String>{};
  for (final tagMatch in linkMetaTagPattern.allMatches(html)) {
    final attrs = parseHtmlAttrs(tagMatch.group(0) ?? '');
    final key = firstNonEmptyString([
      attrs['property'],
      attrs['name'],
    ]).toLowerCase();
    final content = cleanPreviewText(attrs['content'] ?? '');
    if (key.isNotEmpty && content.isNotEmpty) {
      meta[key] = content;
    }
  }
  var title = firstNonEmptyString([meta['og:title'], meta['twitter:title']]);
  if (title.isEmpty) {
    final match = linkTitleTagPattern.firstMatch(html);
    if (match != null) {
      title = cleanPreviewText(match.group(1) ?? '');
    }
  }
  final description = firstNonEmptyString([
    meta['og:description'],
    meta['twitter:description'],
    meta['description'],
  ]);
  var imageUrl = firstNonEmptyString([meta['og:image'], meta['twitter:image']]);
  if (imageUrl.isNotEmpty) {
    imageUrl = baseUri.resolve(imageUrl).toString();
  }
  return LinkPreview(
    url: baseUri.toString(),
    domain: baseUri.host,
    title: title,
    description: description,
    imageUrl: imageUrl,
  );
}

Map<String, String> parseHtmlAttrs(String tag) {
  final attrs = <String, String>{};
  for (final match in linkAttrPattern.allMatches(tag)) {
    final key = match.group(1)?.toLowerCase() ?? '';
    final value = firstNonEmptyString([
      match.group(3),
      match.group(4),
      match.group(5),
    ]);
    if (key.isNotEmpty) attrs[key] = htmlUnescape(value);
  }
  return attrs;
}

String cleanPreviewText(String value) {
  return htmlUnescape(value).replaceAll(linkSpacePattern, ' ').trim();
}

String htmlUnescape(String value) {
  return value
      .replaceAll('&quot;', '"')
      .replaceAll('&#34;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&#39;', "'")
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>');
}

String firstNonEmptyString(Iterable<String?> values) {
  for (final value in values) {
    final text = value?.trim() ?? '';
    if (text.isNotEmpty) return text;
  }
  return '';
}

LinkPreview knownSiteFallback(LinkPreview preview) {
  final host = preview.domain.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
  if (host == 'youtube.com' || host == 'youtu.be') {
    return LinkPreview(
      url: preview.url,
      domain: preview.domain,
      title: 'YouTube',
      description:
          'Enjoy the videos and music you love, upload original content, and share it all with friends, family, and the world on YouTube.',
      imageUrl: preview.imageUrl,
    );
  }
  if (host == 'zhihu.com') {
    return LinkPreview(
      url: preview.url,
      domain: preview.domain,
      title: '知乎 - 有问题，就会有答案',
      description: '知乎，中文互联网高质量的问答社区和创作者聚集的原创内容平台。',
      imageUrl: preview.imageUrl,
    );
  }
  return preview;
}

String faviconPreviewUrl(String domain) {
  final host = domain.trim();
  if (host.isEmpty) return '';
  return 'https://www.google.com/s2/favicons?domain=${Uri.encodeQueryComponent(host)}&sz=128';
}

LinkPreview mergeLinkPreview(LinkPreview preview, LinkPreview fallback) {
  return LinkPreview(
    url: preview.url.trim().isEmpty ? fallback.url : preview.url,
    domain: preview.domain.trim().isEmpty ? fallback.domain : preview.domain,
    title: preview.title.trim().isEmpty ? fallback.title : preview.title,
    description: preview.description.trim().isEmpty
        ? fallback.description
        : preview.description,
    imageUrl: preview.imageUrl,
  );
}

String linkPreviewTitle(LinkPreview preview) {
  final title = preview.title.trim();
  if (title.isNotEmpty) return title;
  return preview.domain.trim();
}

String linkPreviewDescription(LinkPreview preview) {
  final description = preview.description.trim();
  if (description.isEmpty) return '';
  final normalized = normalizePreviewComparable(description);
  final url = normalizePreviewComparable(preview.url);
  final domain = normalizePreviewComparable(preview.domain);
  final title = normalizePreviewComparable(preview.title);
  if (normalized == url || normalized == domain || normalized == title) {
    return '';
  }
  return description;
}

String normalizePreviewComparable(String value) {
  var normalized = value.trim().toLowerCase();
  if (normalized.startsWith('https://')) {
    normalized = normalized.substring('https://'.length);
  } else if (normalized.startsWith('http://')) {
    normalized = normalized.substring('http://'.length);
  }
  if (normalized.endsWith('/')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  return normalized;
}
