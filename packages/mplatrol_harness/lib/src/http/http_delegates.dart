import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// An [HttpClientRequest] that forwards every member to [inner].
///
/// `HttpOverrides` for traffic capture or response stubs extend it and override
/// only what they change.
abstract class DelegatingHttpClientRequest implements HttpClientRequest {
  /// Wraps [inner].
  DelegatingHttpClientRequest(this.inner);

  /// The request the app opened.
  final HttpClientRequest inner;

  @override
  Future<HttpClientResponse> close() => inner.close();
  @override
  Future<HttpClientResponse> get done => inner.done;
  @override
  bool get bufferOutput => inner.bufferOutput;
  @override
  set bufferOutput(bool value) => inner.bufferOutput = value;
  @override
  int get contentLength => inner.contentLength;
  @override
  set contentLength(int value) => inner.contentLength = value;
  @override
  Encoding get encoding => inner.encoding;
  @override
  set encoding(Encoding value) => inner.encoding = value;
  @override
  bool get followRedirects => inner.followRedirects;
  @override
  set followRedirects(bool value) => inner.followRedirects = value;
  @override
  int get maxRedirects => inner.maxRedirects;
  @override
  set maxRedirects(int value) => inner.maxRedirects = value;
  @override
  bool get persistentConnection => inner.persistentConnection;
  @override
  set persistentConnection(bool value) => inner.persistentConnection = value;
  @override
  HttpConnectionInfo? get connectionInfo => inner.connectionInfo;
  @override
  List<Cookie> get cookies => inner.cookies;
  @override
  HttpHeaders get headers => inner.headers;
  @override
  String get method => inner.method;
  @override
  Uri get uri => inner.uri;
  @override
  void abort([Object? exception, StackTrace? stackTrace]) => inner.abort(exception, stackTrace);
  @override
  void add(List<int> data) => inner.add(data);
  @override
  void addError(Object error, [StackTrace? stackTrace]) => inner.addError(error, stackTrace);
  @override
  Future<void> addStream(Stream<List<int>> stream) => inner.addStream(stream);
  @override
  Future<void> flush() => inner.flush();
  @override
  void write(Object? object) => inner.write(object);
  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) => inner.writeAll(objects, separator);
  @override
  void writeCharCode(int charCode) => inner.writeCharCode(charCode);
  @override
  void writeln([Object? object = '']) => inner.writeln(object);
}

/// An [HttpClientResponse] that forwards every member, the body stream included, to [inner].
abstract class DelegatingHttpClientResponse extends Stream<List<int>> implements HttpClientResponse {
  /// Wraps [inner].
  DelegatingHttpClientResponse(this.inner);

  /// The response the server sent.
  final HttpClientResponse inner;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      inner.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  @override
  X509Certificate? get certificate => inner.certificate;
  @override
  HttpClientResponseCompressionState get compressionState => inner.compressionState;
  @override
  HttpConnectionInfo? get connectionInfo => inner.connectionInfo;
  @override
  int get contentLength => inner.contentLength;
  @override
  List<Cookie> get cookies => inner.cookies;
  @override
  Future<Socket> detachSocket() => inner.detachSocket();
  @override
  HttpHeaders get headers => inner.headers;
  @override
  bool get isRedirect => inner.isRedirect;
  @override
  bool get persistentConnection => inner.persistentConnection;
  @override
  String get reasonPhrase => inner.reasonPhrase;
  @override
  Future<HttpClientResponse> redirect([String? method, Uri? url, bool? followLoops]) =>
      inner.redirect(method, url, followLoops);
  @override
  List<RedirectInfo> get redirects => inner.redirects;
  @override
  int get statusCode => inner.statusCode;
}
