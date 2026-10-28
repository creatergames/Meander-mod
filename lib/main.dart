import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const workflowYml = r'''name: Build APK
on:
  workflow_dispatch:
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Unzip
        run: |
          unzip -q project.zip -d app
          echo "DIR=$(dirname "$(find app -name pubspec.yaml | head -1)")" >> $GITHUB_ENV
      - uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: 17
      - uses: subosito/flutter-action@v2
        with:
          channel: stable
          cache: true
      - name: Build
        working-directory: ${{ env.DIR }}
        run: |
          [ -d android ] || flutter create --platforms=android .
          flutter pub get
          flutter build apk --release
      - uses: actions/upload-artifact@v4
        with:
          name: app-release
          path: ${{ env.DIR }}/build/app/outputs/flutter-apk/app-release.apk
''';

void main() => runApp(const MaterialApp(home: Home()));

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  final tokenC = TextEditingController();
  final repoC = TextEditingController();
  final logs = <String>[];
  bool busy = false;

  Map<String, String> get _h => {
        'Authorization': 'Bearer ${tokenC.text.trim()}',
        'Accept': 'application/vnd.github+json',
      };
  String _api(String p) => 'https://api.github.com/repos/${repoC.text.trim()}$p';

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      tokenC.text = p.getString('token') ?? '';
      repoC.text = p.getString('repo') ?? '';
    });
  }

  void _log(String s) => setState(() => logs.add(s));

  Future<http.Response> _get(String p) => http.get(Uri.parse(_api(p)), headers: _h);

  Future<void> _put(String path, List<int> bytes, String msg) async {
    final cur = await _get('/contents/$path');
    final res = await http.put(
      Uri.parse(_api('/contents/$path')),
      headers: _h,
      body: jsonEncode({
        'message': msg,
        'content': base64Encode(bytes),
        if (cur.statusCode == 200) 'sha': jsonDecode(cur.body)['sha'],
      }),
    );
    if (res.statusCode != 200 && res.statusCode != 201) {
      throw 'Загрузка $path: ${res.statusCode} ${res.body}';
    }
  }

  Future<void> _build() async {
    final pick = await FilePicker.platform
        .pickFiles(type: FileType.custom, allowedExtensions: ['zip']);
    if (pick == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('token', tokenC.text.trim());
    await prefs.setString('repo', repoC.text.trim());
    setState(() {
      busy = true;
      logs.clear();
    });
    try {
      final repo = await _get('');
      if (repo.statusCode != 200) throw 'Репозиторий недоступен: ${repo.statusCode}';
      final branch = jsonDecode(repo.body)['default_branch'];

      final wf = await _get('/contents/.github/workflows/build.yml');
      if (wf.statusCode != 200) {
        _log('Создаю workflow...');
        await _put('.github/workflows/build.yml', utf8.encode(workflowYml), 'add workflow');
        await Future.delayed(const Duration(seconds: 4));
      }

      _log('Загружаю zip...');
      final bytes = await File(pick.files.single.path!).readAsBytes();
      await _put('project.zip', bytes, 'upload project');

      final prev = await _get('/actions/runs?per_page=1');
      final runs0 = jsonDecode(prev.body)['workflow_runs'] as List;
      final prevId = runs0.isEmpty ? 0 : runs0[0]['id'] as int;

      _log('Запускаю сборку...');
      final d = await http.post(
        Uri.parse(_api('/actions/workflows/build.yml/dispatches')),
        headers: _h,
        body: jsonEncode({'ref': branch}),
      );
      if (d.statusCode != 204) throw 'Запуск: ${d.statusCode} ${d.body}';

      Map run = {};
      for (var i = 0; i < 40; i++) {
        await Future.delayed(const Duration(seconds: 4));
        final r = jsonDecode((await _get('/actions/runs?per_page=5')).body)['workflow_runs'] as List;
        final fresh = r.where((e) => e['id'] > prevId).toList();
        if (fresh.isNotEmpty) {
          run = fresh.first;
          break;
        }
      }
      if (run.isEmpty) throw 'Сборка не появилась';

      while (run['status'] != 'completed') {
        _log('Сборка: ${run['status']}...');
        await Future.delayed(const Duration(seconds: 10));
        run = jsonDecode((await _get('/actions/runs/${run['id']}')).body);
      }
      if (run['conclusion'] != 'success') {
        throw 'Сборка упала: ${run['html_url']}';
      }

      _log('Скачиваю APK...');
      final arts = jsonDecode((await _get('/actions/runs/${run['id']}/artifacts')).body)['artifacts'] as List;
      final url = arts.first['archive_download_url'] as String;
      final req = http.Request('GET', Uri.parse(url))
        ..followRedirects = false
        ..headers.addAll(_h);
      final resp = await http.Client().send(req);
      final loc = resp.headers['location'];
      if (loc == null) throw 'Нет ссылки на артефакт (${resp.statusCode})';
      final zip = await http.get(Uri.parse(loc));
      final arc = ZipDecoder().decodeBytes(zip.bodyBytes);
      final apk = arc.files.firstWhere((f) => f.name.endsWith('.apk'));
      final dir = (await getExternalStorageDirectory()) ?? await getTemporaryDirectory();
      final out = File('${dir.path}/app-release.apk');
      await out.writeAsBytes(apk.content as List<int>);
      _log('Готово: ${out.path}');
      await OpenFilex.open(out.path);
    } catch (e) {
      _log('Ошибка: $e');
    } finally {
      setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Zip → APK')),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(children: [
            TextField(
              controller: tokenC,
              obscureText: true,
              decoration: const InputDecoration(
                  labelText: 'GitHub token (repo + workflow)'),
            ),
            TextField(
              controller: repoC,
              decoration: const InputDecoration(labelText: 'Репозиторий: user/repo'),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: busy ? null : _build,
              icon: const Icon(Icons.archive),
              label: Text(busy ? 'Идёт сборка...' : 'Выбрать zip и собрать'),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: ListView(children: [for (final l in logs) Text(l)]),
            ),
          ]),
        ),
      );
}
