import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:args/args.dart';
import 'package:flutter_lokalise/src/arb_converter/json_to_arb_converter.dart';
import 'package:flutter_lokalise/src/client/downloader.dart';
import 'package:flutter_lokalise/src/client/lokalise_client.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;

import 'arg_results_extension.dart';
import 'flutter_lokalise_command.dart';

class DownloadCommand extends FlutterLokaliseCommand<Null> {
  final Logger _logger = Logger.root;
  final Downloader _downloader;
  final String? _baseUrl;

  @override
  String get description => "Downloads translation files from Lokalise.";

  @override
  String get name => "download";

  DownloadCommand({
    Downloader? downloader,
    String? baseUrl,
  })  : _downloader = downloader ?? Downloader(),
        _baseUrl = baseUrl {
    _DownloadArgResults.addOptions(argParser);
  }

  @override
  FutureOr<Null> run() async {
    final config = commandRunner.lokaliseConfig;
    final flutterLokaliseArgResults = commandRunner.flutterLokaliseArgResults;
    final downloadArgResults = _DownloadArgResults.fromArgResults(
      argResults!,
      fallbackOutput: config.output,
      fallbackIncludeTags: config.includeTags,
    );

    final bundleUrl = await _fetchBundleUrl(
      apiToken: flutterLokaliseArgResults!.apiToken!,
      projectId: flutterLokaliseArgResults.projectId!,
      includeTags: downloadArgResults.includeTags!,
    );

    final bundleData = await _downloader.download(bundleUrl);
    final archive = ZipDecoder().decodeBytes(bundleData);
    _convertArchiveToArbFiles(archive, downloadArgResults.output!);
  }

  Future<String> _fetchBundleUrl({
    required String apiToken,
    required String projectId,
    required Iterable<String> includeTags,
  }) async {
    final client = LokaliseClient(
      apiToken: apiToken,
      baseUrl: _baseUrl,
    );

    final response = await client.download(
      projectId: projectId,
      includeTags: includeTags,
    );

    if (response.innerResponse.statusCode == 413) {
      _logger.info('Project too large for sync export, using async export...');
      return _fetchBundleUrlAsync(
        client: client,
        projectId: projectId,
        includeTags: includeTags,
      );
    }

    if (!response.wasSuccessful) {
      throw Exception(
          'Lokalise API error (${response.innerResponse.statusCode}): '
          '${response.innerResponse.body}');
    }
    final body = response.typedBody;
    _logger.fine(body);
    final bundleUrl = body.bundleUrl;
    if (bundleUrl == null) {
      throw Exception(
          'Lokalise API returned no bundle_url. Response: '
          '${response.innerResponse.body}');
    }
    return bundleUrl;
  }

  Future<String> _fetchBundleUrlAsync({
    required LokaliseClient client,
    required String projectId,
    required Iterable<String> includeTags,
  }) async {
    final response = await client.asyncDownload(
      projectId: projectId,
      includeTags: includeTags,
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
          'Lokalise async export error (${response.statusCode}): '
          '${response.body}');
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final processId = body['process_id'] as String?;
    if (processId == null) {
      throw Exception(
          'Lokalise async export returned no process_id. Response: '
          '${response.body}');
    }

    _logger.info('Async export started (process: $processId). Polling...');
    return _pollForBundleUrl(
      client: client,
      projectId: projectId,
      processId: processId,
    );
  }

  Future<String> _pollForBundleUrl({
    required LokaliseClient client,
    required String projectId,
    required String processId,
  }) async {
    const maxAttempts = 60;
    const pollInterval = Duration(seconds: 3);

    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      await Future.delayed(pollInterval);

      final response = await client.getProcess(
        projectId: projectId,
        processId: processId,
      );

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception(
            'Lokalise process status error (${response.statusCode}): '
            '${response.body}');
      }

      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final process = body['process'] as Map<String, dynamic>?;
      final status = process?['status'] as String?;

      _logger.fine('Process status: $status (attempt ${attempt + 1})');

      if (status == 'finished') {
        final detail = process?['detail'] as Map<String, dynamic>?;
        final bundleUrl = detail?['bundle_url'] as String?;
        if (bundleUrl == null) {
          throw Exception(
              'Lokalise async export finished but no bundle_url in response: '
              '${response.body}');
        }
        return bundleUrl;
      } else if (status == 'failed' || status == 'cancelled') {
        final message = process?['message'] as String? ?? 'unknown error';
        throw Exception('Lokalise async export $status: $message');
      }
    }

    throw Exception(
        'Lokalise async export timed out after ${maxAttempts * pollInterval.inSeconds} seconds');
  }

  void _convertArchiveToArbFiles(Archive archive, String output) {
    final converter = JsonToArbConverter();
    archive
        .where((it) => it.isFile && path.extension(it.name) == ".json")
        .forEach((it) {
      final data = it.content as List<int>;
      final jsonString = Utf8Decoder().convert(data);
      final json = jsonDecode(jsonString) as Map<String, dynamic>;
      final locale = path.basenameWithoutExtension(it.name);
      final arbMap = converter.toArb(
        json: json,
        locale: locale,
      );
      File("$output/intl_$locale.arb")
        ..createSync(recursive: true)
        ..writeAsStringSync(
            _unescape(JsonEncoder.withIndent("  ").convert(arbMap)));
    });
  }

  String _unescape(String input) {
    return input.replaceAll(r'\\n', r'\n');
  }
}

class _DownloadArgResults {
  final String? output;
  final Iterable<String>? includeTags;

  _DownloadArgResults.fromArgResults(
    ArgResults results, {
    String? fallbackOutput,
    Iterable<String>? fallbackIncludeTags,
  })  : output = results.get("output", orElse: fallbackOutput),
        includeTags = results.get("include-tags", orElse: fallbackIncludeTags);

  static void addOptions(ArgParser argParser) {
    argParser.addOption(
      "output",
      abbr: "o",
      help: "destination for ARB files",
      defaultsTo: "lib/l10n",
    );
    argParser.addMultiOption(
      "include-tags",
      abbr: "t",
      help: "tags to filter the keys by",
    );
  }
}
