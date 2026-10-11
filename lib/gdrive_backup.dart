import 'dart:io';

import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:path/path.dart' as p;

import 'db.dart';

/// نسخة موجودة على جوجل درايف
class DriveBackupInfo {
  final String id;
  final String name;
  final int size;
  final DateTime created;
  DriveBackupInfo(this.id, this.name, this.size, this.created);

  String get kindLabel {
    if (name.startsWith('auto_')) return 'تلقائية';
    if (name.startsWith('prerestore_')) return 'قبل الاستعادة';
    return 'يدوية';
  }
}

/// نسخة احتياطية إضافية على جوجل درايف (بجانب النسخة المحلية دائماً).
/// تُحفظ في مجلد «RentPal Backups» على درايف الخاص بحسابك، وصلاحية التطبيق
/// محصورة بالملفات التي ينشئها هو فقط (drive.file) فلا يرى بقية ملفاتك.
class GDriveBackup {
  static const _kEnabled = 'gdrive_enabled';
  static const _kEmail = 'gdrive_email';
  static const _kLast = 'gdrive_last';
  static const _kError = 'gdrive_error';
  static const _kPending = 'gdrive_pending';
  static const folderName = 'RentPal Backups';

  static final GoogleSignIn _gsi =
      GoogleSignIn(scopes: [drive.DriveApi.driveFileScope]);

  // ---------------- الإعدادات ----------------
  static Future<bool> enabled() async =>
      (await DB.getSetting(_kEnabled)) == '1';
  static Future<void> setEnabled(bool v) =>
      DB.setSetting(_kEnabled, v ? '1' : '0');
  static Future<String> email() async => (await DB.getSetting(_kEmail)) ?? '';
  static Future<String> lastError() async =>
      (await DB.getSetting(_kError)) ?? '';
  static Future<DateTime?> lastUpload() async =>
      DateTime.tryParse((await DB.getSetting(_kLast)) ?? '');
  static Future<bool> hasPending() async =>
      ((await DB.getSetting(_kPending)) ?? '').isNotEmpty;

  // ---------------- الحساب ----------------
  /// يفتح نافذة اختيار حساب جوجل ويرجع البريد
  static Future<String> signIn() async {
    final acc = await _gsi.signIn();
    if (acc == null) throw Exception('تم إلغاء تسجيل الدخول');
    await DB.setSetting(_kEmail, acc.email);
    await DB.setSetting(_kError, '');
    return acc.email;
  }

  static Future<void> signOut() async {
    try {
      await _gsi.signOut();
    } catch (_) {}
    await setEnabled(false);
    await DB.setSetting(_kEmail, '');
    await DB.setSetting(_kPending, '');
    await DB.setSetting(_kError, '');
  }

  // ---------------- الاتصال ----------------
  static Future<T> _withApi<T>(Future<T> Function(drive.DriveApi api) job) async {
    var acc = _gsi.currentUser;
    acc ??= await _gsi.signInSilently();
    if (acc == null) {
      throw Exception('سجّل الدخول بحساب جوجل أولاً (الإعدادات > النسخ الاحتياطي)');
    }
    final client = await _gsi.authenticatedClient();
    if (client == null) {
      throw Exception('تعذر الحصول على صلاحية جوجل درايف، أعد تسجيل الدخول');
    }
    try {
      return await job(drive.DriveApi(client));
    } finally {
      client.close();
    }
  }

  static Future<String> _folderId(drive.DriveApi api) async {
    final q =
        "name='$folderName' and mimeType='application/vnd.google-apps.folder' and trashed=false";
    final res = await api.files.list(q: q, spaces: 'drive', $fields: 'files(id)');
    final f = res.files;
    if (f != null && f.isNotEmpty && f.first.id != null) return f.first.id!;
    final created = await api.files.create(
      drive.File()
        ..name = folderName
        ..mimeType = 'application/vnd.google-apps.folder',
      $fields: 'id',
    );
    return created.id!;
  }

  // ---------------- رفع / قائمة / تنزيل ----------------
  static Future<void> upload(File f) async {
    await _withApi<void>((api) async {
      final folder = await _folderId(api);
      final len = await f.length();
      await api.files.create(
        drive.File()
          ..name = p.basename(f.path)
          ..parents = [folder],
        uploadMedia: drive.Media(f.openRead(), len),
        $fields: 'id',
      );
    });
  }

  static Future<List<DriveBackupInfo>> list() async {
    return _withApi<List<DriveBackupInfo>>((api) async {
      final folder = await _folderId(api);
      final res = await api.files.list(
        q: "'$folder' in parents and trashed=false",
        spaces: 'drive',
        orderBy: 'createdTime desc',
        pageSize: 100,
        $fields: 'files(id,name,size,createdTime)',
      );
      return [
        for (final x in res.files ?? <drive.File>[])
          if (x.id != null && (x.name ?? '').endsWith('.zip'))
            DriveBackupInfo(x.id!, x.name!, int.tryParse(x.size ?? '') ?? 0,
                x.createdTime?.toLocal() ?? DateTime.now())
      ];
    });
  }

  /// ينزّل نسخة من درايف إلى ملف محلي
  static Future<void> download(DriveBackupInfo b, File dest) async {
    await _withApi<void>((api) async {
      final media = await api.files.get(b.id,
          downloadOptions: drive.DownloadOptions.fullMedia) as drive.Media;
      final sink = dest.openWrite();
      try {
        await media.stream.pipe(sink);
      } finally {
        await sink.close();
      }
    });
  }

  /// يحتفظ بآخر [keep] نسخة تلقائية على درايف فقط
  static Future<void> _prune(int keep) async {
    try {
      final all = await list();
      final autos = all.where((b) => b.name.startsWith('auto_')).toList();
      if (autos.length <= keep) return;
      await _withApi<void>((api) async {
        for (final b in autos.skip(keep)) {
          try {
            await api.files.delete(b.id);
          } catch (_) {}
        }
      });
    } catch (_) {}
  }

  static String explain(Object e) {
    final raw = e.toString();
    final s = raw.toLowerCase();
    if (s.contains('apiexception: 10') ||
        s.contains('sign_in_failed') ||
        s.contains('developer_error')) {
      return 'إعداد تسجيل الدخول بجوجل غير مكتمل (OAuth Client / SHA-1). راجع شرح الإعداد أسفل القسم';
    }
    if (s.contains('network') ||
        s.contains('socket') ||
        s.contains('connection') ||
        s.contains('host lookup')) {
      return 'لا يوجد اتصال بالإنترنت';
    }
    if (s.contains('403') || s.contains('accessnotconfigured') || s.contains('has not been used')) {
      return 'واجهة Google Drive API غير مفعّلة في مشروع جوجل كلاود';
    }
    if (s.contains('401') || s.contains('invalid_token')) {
      return 'انتهت صلاحية الدخول، أعد تسجيل الدخول بحساب جوجل';
    }
    final msg = raw.replaceFirst('Exception: ', '');
    return msg.length > 140 ? '${msg.substring(0, 140)}...' : msg;
  }

  static Future<void> markOk() async {
    await DB.setSetting(_kLast, DateTime.now().toIso8601String());
    await DB.setSetting(_kError, '');
    await DB.setSetting(_kPending, '');
  }

  // ---------------- التكامل مع النسخ الاحتياطي ----------------
  /// بعد كل نسخة محلية: null = غير مفعّل | true = تم الرفع | false = فشل (تُعاد المحاولة لاحقاً)
  static Future<bool?> afterBackup(File f, String prefix) async {
    try {
      if (!await enabled()) return null;
    } catch (_) {
      return null;
    }
    try {
      await upload(f);
      await DB.setSetting(_kLast, DateTime.now().toIso8601String());
      await DB.setSetting(_kError, '');
      await DB.setSetting(_kPending, '');
      if (prefix == 'auto') {
        final keep = int.tryParse(await DB.getSetting('backup_keep') ?? '') ?? 10;
        await _prune(keep);
      }
      return true;
    } catch (e) {
      try {
        await DB.setSetting(_kError, explain(e));
        await DB.setSetting(_kPending, f.path);
      } catch (_) {}
      return false;
    }
  }

  /// إعادة محاولة رفع نسخة فشل رفعها (مثلاً كان الإنترنت مقطوعاً)
  static Future<void> retryPending() async {
    try {
      if (!await enabled()) return;
      final path = (await DB.getSetting(_kPending)) ?? '';
      if (path.isEmpty) return;
      final f = File(path);
      if (!await f.exists()) {
        await DB.setSetting(_kPending, '');
        return;
      }
      try {
        await upload(f);
        await DB.setSetting(_kLast, DateTime.now().toIso8601String());
        await DB.setSetting(_kError, '');
        await DB.setSetting(_kPending, '');
      } catch (e) {
        await DB.setSetting(_kError, explain(e));
      }
    } catch (_) {}
  }
}
