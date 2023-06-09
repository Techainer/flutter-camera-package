// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:process/process.dart';

import '../base/command.dart';
import '../base/file_system.dart';
import '../base/logger.dart';
import '../base/project.dart';

import '../compute.dart';
import '../environment.dart';
import '../manifest.dart';
import '../result.dart';
import '../utils.dart';

class MigrateStartCommand extends MigrateCommand {
  MigrateStartCommand({
    bool verbose = false,
    required this.logger,
    required this.fileSystem,
    required this.processManager,
    this.standalone = false,
  })  : _verbose = verbose,
        migrateUtils = MigrateUtils(
          logger: logger,
          fileSystem: fileSystem,
          processManager: processManager,
        ) {
    argParser.addOption(
      'staging-directory',
      help:
          'Specifies the custom migration staging directory used to stage and edit proposed changes. '
          'This path can be absolute or relative to the flutter project root.',
      valueHelp: 'path',
    );
    argParser.addOption(
      'project-directory',
      help: 'The root directory of the flutter project.',
      valueHelp: 'path',
    );
    argParser.addOption(
      'platforms',
      help:
          'Restrict the tool to only migrate the listed platforms. By default all platforms generated by '
          'flutter create will be migrated. To indicate the project root, use the `root` platform',
      valueHelp: 'root,android,ios,windows...',
    );
    argParser.addFlag(
      'delete-temp-directories',
      help:
          'Indicates if the temporary directories created by the migrate tool will be deleted.',
    );
    argParser.addOption(
      'base-app-directory',
      help:
          'The directory containing the base reference app. This is used as the common ancestor in a 3 way merge. '
          'Providing this directory will prevent the tool from generating its own. This is primarily used '
          'in testing and CI.',
      valueHelp: 'path',
      hide: !verbose,
    );
    argParser.addOption(
      'target-app-directory',
      help:
          'The directory containing the target reference app. This is used as the target app in 3 way merge. '
          'Providing this directory will prevent the tool from generating its own. This is primarily used '
          'in testing and CI.',
      valueHelp: 'path',
      hide: !verbose,
    );
    argParser.addFlag(
      'allow-fallback-base-revision',
      help:
          'If a base revision cannot be determined, this flag enables using flutter 1.0.0 as a fallback base revision. '
          'Using this fallback will typically produce worse quality migrations and possibly more conflicts.',
    );
    argParser.addOption(
      'base-revision',
      help:
          'Manually sets the base revision to generate the base ancestor reference app with. This may be used '
          'if the tool is unable to determine an appropriate base revision.',
      valueHelp: 'git revision hash',
    );
    argParser.addOption(
      'target-revision',
      help:
          'Manually sets the target revision to generate the target reference app with. Passing this indicates '
          'that the current flutter sdk version is not the version that should be migrated to.',
      valueHelp: 'git revision hash',
    );
    argParser.addFlag(
      'prefer-two-way-merge',
      negatable: false,
      help:
          'Avoid three way merges when possible. Enabling this effectively ignores the base ancestor reference '
          'files when a merge is required, opting for a simpler two way merge instead. In some edge cases typically '
          'involving using a fallback or incorrect base revision, the default three way merge algorithm may produce '
          'incorrect merges. Two way merges are more conflict prone, but less likely to produce incorrect results '
          'silently.',
    );
    argParser.addFlag(
      'flutter-subcommand',
      help:
          'Enable when using the flutter tool as a subcommand. This changes the '
          'wording of log messages to indicate the correct suggested commands to use.',
    );
  }

  final bool _verbose;

  final Logger logger;

  final FileSystem fileSystem;

  final MigrateUtils migrateUtils;

  final ProcessManager processManager;

  final bool standalone;

  @override
  final String name = 'start';

  @override
  final String description =
      r'Begins a new migration. Computes the changes needed to migrate the project from the base revision of Flutter to the current revision of Flutter and outputs the results in a working directory. Use `$ flutter migrate apply` accept and apply the changes.';

  @override
  Future<CommandResult> runCommand() async {
    final FlutterToolsEnvironment environment =
        await FlutterToolsEnvironment.initializeFlutterToolsEnvironment(
            processManager, logger);
    if (!_validateEnvironment(environment)) {
      return const CommandResult(ExitStatus.fail);
    }
    final String? projectRootDirPath = stringArg('project-directory') ??
        environment.getString('FlutterProject.directory');
    final Directory projectRootDir = fileSystem.directory(projectRootDirPath);
    final FlutterProjectFactory flutterProjectFactory = FlutterProjectFactory();
    final FlutterProject project = projectRootDirPath == null
        ? FlutterProject.current(fileSystem)
        : flutterProjectFactory
            .fromDirectory(fileSystem.directory(projectRootDirPath));

    if (!validateWorkingDirectory(project, logger)) {
      return CommandResult.fail();
    }

    final bool isModule =
        environment.getBool('FlutterProject.isModule') ?? false;
    final bool isPlugin =
        environment.getBool('FlutterProject.isPlugin') ?? false;
    if (isModule || isPlugin) {
      logger.printError(
          'Migrate tool only supports app projects. This project is a ${isModule ? 'module' : 'plugin'}');
      return const CommandResult(ExitStatus.fail);
    }
    final bool isSubcommand = boolArg('flutter-subcommand') ?? !standalone;

    if (!await gitRepoExists(project.directory.path, logger, migrateUtils)) {
      return const CommandResult(ExitStatus.fail);
    }

    Directory stagingDirectory =
        project.directory.childDirectory(kDefaultMigrateStagingDirectoryName);
    final String? customStagingDirectoryPath = stringArg('staging-directory');
    if (customStagingDirectoryPath != null) {
      if (fileSystem.path.isAbsolute(customStagingDirectoryPath)) {
        stagingDirectory = fileSystem.directory(customStagingDirectoryPath);
      } else {
        stagingDirectory =
            project.directory.childDirectory(customStagingDirectoryPath);
      }
    }
    if (stagingDirectory.existsSync()) {
      logger.printStatus('Old migration already in progress.', emphasis: true);
      logger.printStatus(
          'Pending migration files exist in `${stagingDirectory.path}/$kDefaultMigrateStagingDirectoryName`');
      logger.printStatus(
          'Resolve merge conflicts and accept changes with by running:');
      printCommandText('apply', logger, standalone: !isSubcommand);
      logger.printStatus(
          'You may also abandon the existing migration and start a new one with:');
      printCommandText('abandon', logger, standalone: !isSubcommand);
      return const CommandResult(ExitStatus.fail);
    }

    if (await hasUncommittedChanges(
        project.directory.path, logger, migrateUtils)) {
      return const CommandResult(ExitStatus.fail);
    }

    List<SupportedPlatform>? platforms;
    if (stringArg('platforms') != null) {
      platforms = <SupportedPlatform>[];
      for (String platformString in stringArg('platforms')!.split(',')) {
        platformString = platformString.trim();
        platforms.add(SupportedPlatform.values.firstWhere(
            (SupportedPlatform val) =>
                val.toString() == 'SupportedPlatform.$platformString'));
      }
    }

    final MigrateCommandParameters commandParameters = MigrateCommandParameters(
      verbose: _verbose,
      baseAppPath: stringArg('base-app-directory'),
      targetAppPath: stringArg('target-app-directory'),
      baseRevision: stringArg('base-revision'),
      targetRevision: stringArg('target-revision'),
      deleteTempDirectories: boolArg('delete-temp-directories') ?? true,
      platforms: platforms,
      preferTwoWayMerge: boolArg('prefer-two-way-merge') ?? false,
      allowFallbackBaseRevision:
          boolArg('allow-fallback-base-revision') ?? false,
    );

    final MigrateResult? migrateResult = await computeMigration(
      flutterProject: project,
      commandParameters: commandParameters,
      fileSystem: fileSystem,
      logger: logger,
      migrateUtils: migrateUtils,
      environment: environment,
    );
    if (migrateResult == null) {
      return const CommandResult(ExitStatus.fail);
    }

    await writeStagingDir(migrateResult, logger,
        verbose: _verbose, projectRootDir: projectRootDir);

    _deleteTempDirectories(
      paths: <String>[],
      directories: migrateResult.tempDirectories,
    );

    logger.printStatus(
        'The migrate tool has staged proposed changes in the migrate staging directory.\n');
    logger.printStatus('Guided conflict resolution wizard:');
    printCommandText('resolve-conflicts', logger, standalone: !isSubcommand);
    logger.printStatus('Check the status and diffs of the migration with:');
    printCommandText('status', logger, standalone: !isSubcommand);
    logger.printStatus('Abandon the proposed migration with:');
    printCommandText('abandon', logger, standalone: !isSubcommand);
    logger.printStatus(
        'Accept staged changes after resolving any merge conflicts with:');
    printCommandText('apply', logger, standalone: !isSubcommand);

    return const CommandResult(ExitStatus.success);
  }

  /// Deletes the files or directories at the provided paths.
  void _deleteTempDirectories(
      {List<String> paths = const <String>[],
      List<Directory> directories = const <Directory>[]}) {
    for (final Directory d in directories) {
      try {
        d.deleteSync(recursive: true);
      } on FileSystemException catch (e) {
        logger.printError(
            'Unabled to delete ${d.path} due to ${e.message}, please clean up manually.');
      }
    }
    for (final String p in paths) {
      try {
        fileSystem.directory(p).deleteSync(recursive: true);
      } on FileSystemException catch (e) {
        logger.printError(
            'Unabled to delete $p due to ${e.message}, please clean up manually.');
      }
    }
  }

  bool _validateEnvironment(FlutterToolsEnvironment environment) {
    if (environment.getString('FlutterProject.directory') == null) {
      logger.printError(
          'No valid flutter project found. This command must be run from a flutter project directory');
      return false;
    }
    if (environment.getString('FlutterProject.manifest.appname') == null) {
      logger.printError('No app name found in project pubspec.yaml');
      return false;
    }
    if (!(environment.getBool('FlutterProject.android.exists') ?? false) &&
        environment['FlutterProject.android.isKotlin'] == null) {
      logger.printError(
          'Could not detect if android project uses kotlin or java');
      return false;
    }
    if (!(environment.getBool('FlutterProject.ios.exists') ?? false) &&
        environment['FlutterProject.ios.isSwift'] == null) {
      logger.printError(
          'Could not detect if iosProject uses swift or objective-c');
      return false;
    }
    return true;
  }

  /// Writes the files into the working directory for the developer to review and resolve any conflicts.
  Future<void> writeStagingDir(MigrateResult migrateResult, Logger logger,
      {bool verbose = false, required Directory projectRootDir}) async {
    final Directory stagingDir =
        projectRootDir.childDirectory(kDefaultMigrateStagingDirectoryName);
    if (verbose) {
      logger.printStatus(
          'Writing migrate staging directory at `${stagingDir.path}`');
    }
    // Write files in working dir
    for (final MergeResult result in migrateResult.mergeResults) {
      final File file = stagingDir.childFile(result.localPath);
      file.createSync(recursive: true);
      if (result is StringMergeResult) {
        file.writeAsStringSync(result.mergedString, flush: true);
      } else {
        file.writeAsBytesSync((result as BinaryMergeResult).mergedBytes,
            flush: true);
      }
    }

    // Write all files that are newly added in target
    for (final FilePendingMigration addedFile in migrateResult.addedFiles) {
      final File file = stagingDir.childFile(addedFile.localPath);
      file.createSync(recursive: true);
      try {
        file.writeAsStringSync(addedFile.file.readAsStringSync(), flush: true);
      } on FileSystemException {
        file.writeAsBytesSync(addedFile.file.readAsBytesSync(), flush: true);
      }
    }

    // Write the MigrateManifest.
    final MigrateManifest manifest = MigrateManifest(
      migrateRootDir: stagingDir,
      migrateResult: migrateResult,
    );
    manifest.writeFile();

    // output the manifest contents.
    checkAndPrintMigrateStatus(manifest, stagingDir, logger: logger);

    logger.printBox('Staging directory created at `${stagingDir.path}`');
  }
}
