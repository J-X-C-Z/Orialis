part of 'sync_engine.dart';

extension ProjectSyncHandler on SyncEngine {
  Future<void> _pushProjects(OrialisApiClient api) async {
    final rows = await (database.select(
      database.projects,
    )..where((row) => row.syncStatus.isNotIn(const ['synced']))).get();
    final outbox = _outboxStore;
    for (final project in rows) {
      final mutation =
          await outbox.findPendingForEntity('project', project.id) ??
          await outbox.enqueue(
            entityType: 'project',
            entityId: project.id,
            operation: _operationFor(project.syncStatus),
            payloadJson: jsonEncode({
              'id': project.id,
              'name': project.name,
              'goal': project.goal,
              'description': project.description,
              'color': project.color,
              'status': project.status,
              'startDate': project.startDate,
              'due': project.due,
              'nextActionTaskId': project.nextActionTaskId,
              'manualPosition': project.manualPosition,
              'version': project.version,
              'createdAt': project.createdAt,
              'updatedAt': project.updatedAt,
              'deletedAt': project.deletedAt,
            }),
            baseVersion:
                project.syncStatus == 'pendingUpdate' ||
                    project.syncStatus == 'pendingDelete'
                ? project.remoteVersion
                : null,
            entityRevision: project.localRevision,
          );
      await outbox.markInFlight(mutation.mutationId);
      try {
        final payload =
            jsonDecode(mutation.payloadJson) as Map<String, dynamic>;
        Map<String, dynamic> result = {};
        if (mutation.operation == 'create') {
          result = await api.createProject(payload, mutation.mutationId);
        } else if (mutation.operation == 'delete') {
          await api.deleteProject(project.id, mutation.mutationId);
        } else {
          result = await api.updateProject(project.id, {
            ...payload,
            'baseVersion': mutation.baseVersion,
          }, mutation.mutationId);
        }
        final remoteVersion =
            (result['version'] as num?)?.toInt() ?? project.remoteVersion + 1;
        await database.transaction(() async {
          final current = await (database.select(
            database.projects,
          )..where((r) => r.id.equals(project.id))).getSingle();
          await (database.update(
            database.projects,
          )..where((r) => r.id.equals(project.id))).write(
            ProjectsCompanion(
              version: Value(remoteVersion),
              remoteVersion: Value(remoteVersion),
              syncStatus: Value(
                current.localRevision == mutation.entityRevision
                    ? 'synced'
                    : current.syncStatus == 'pendingCreate'
                    ? 'pendingUpdate'
                    : current.syncStatus,
              ),
            ),
          );
          await outbox.rebasePendingForEntity(
            entityType: 'project',
            entityId: project.id,
            baseVersion: remoteVersion,
          );
          await outbox.acknowledge(mutation.mutationId);
        });
      } on DioException catch (error) {
        if (error.response?.statusCode == 409) {
          await outbox.markConflict(mutation.mutationId, error);
        } else if (_isRetryableTransportError(error)) {
          await outbox.markRetryable(mutation.mutationId, error);
        } else {
          await outbox.markFailed(mutation.mutationId, error);
        }
        rethrow;
      }
    }
  }

  Future<void> _pushProjectMilestones(OrialisApiClient api) async {
    final rows = await (database.select(
      database.projectMilestones,
    )..where((row) => row.syncStatus.isNotIn(const ['synced']))).get();
    final outbox = _outboxStore;
    for (final milestone in rows) {
      final mutation =
          await outbox.findPendingForEntity(
            'project_milestone',
            milestone.id,
          ) ??
          await outbox.enqueue(
            entityType: 'project_milestone',
            entityId: milestone.id,
            operation: _operationFor(milestone.syncStatus),
            payloadJson: jsonEncode({
              'id': milestone.id,
              'projectId': milestone.projectId,
              'title': milestone.title,
              'due': milestone.due,
              'completed': milestone.completed,
              'completedAt': milestone.completedAt,
              'position': milestone.position,
              'version': milestone.version,
              'createdAt': milestone.createdAt,
              'updatedAt': milestone.updatedAt,
              'deletedAt': milestone.deletedAt,
            }),
            baseVersion:
                milestone.syncStatus == 'pendingUpdate' ||
                    milestone.syncStatus == 'pendingDelete'
                ? milestone.remoteVersion
                : null,
            entityRevision: milestone.localRevision,
          );
      await outbox.markInFlight(mutation.mutationId);
      try {
        final payload =
            jsonDecode(mutation.payloadJson) as Map<String, dynamic>;
        Map<String, dynamic> result = {};
        if (mutation.operation == 'create') {
          result = await api.createProjectMilestone(
            milestone.projectId,
            payload,
            mutation.mutationId,
          );
        } else if (mutation.operation == 'delete') {
          await api.deleteProjectMilestone(
            milestone.projectId,
            milestone.id,
            mutation.mutationId,
          );
        } else {
          result = await api.updateProjectMilestone(
            milestone.projectId,
            milestone.id,
            {...payload, 'baseVersion': mutation.baseVersion},
            mutation.mutationId,
          );
        }
        final remoteVersion =
            (result['version'] as num?)?.toInt() ?? milestone.remoteVersion + 1;
        await database.transaction(() async {
          final current = await (database.select(
            database.projectMilestones,
          )..where((row) => row.id.equals(milestone.id))).getSingle();
          await (database.update(
            database.projectMilestones,
          )..where((row) => row.id.equals(milestone.id))).write(
            ProjectMilestonesCompanion(
              version: Value(remoteVersion),
              remoteVersion: Value(remoteVersion),
              syncStatus: Value(
                current.localRevision == mutation.entityRevision
                    ? 'synced'
                    : current.syncStatus == 'pendingCreate'
                    ? 'pendingUpdate'
                    : current.syncStatus,
              ),
            ),
          );
          await outbox.rebasePendingForEntity(
            entityType: 'project_milestone',
            entityId: milestone.id,
            baseVersion: remoteVersion,
          );
          await outbox.acknowledge(mutation.mutationId);
        });
      } on DioException catch (error) {
        if (error.response?.statusCode == 409) {
          await outbox.markConflict(mutation.mutationId, error);
        } else if (_isRetryableTransportError(error)) {
          await outbox.markRetryable(mutation.mutationId, error);
        } else {
          await outbox.markFailed(mutation.mutationId, error);
        }
        rethrow;
      }
    }
  }

  Future<void> _applyProjectEvent(Map<String, dynamic> event) async {
    final isProject = event['entityType'] == 'project';
    final TableInfo<Table, Object?> table = isProject
        ? database.projects
        : database.projectMilestones;
    final id = event['entityId'] as String;
    final version = event['entityVersion'] as int;
    final existing = await database
        .customSelect(
          'SELECT remote_version, sync_status FROM ${table.actualTableName} WHERE id = ?',
          variables: [Variable<String>(id)],
          readsFrom: {table},
        )
        .getSingleOrNull();
    // A tombstone can arrive before this client ever saw the entity. Its payload
    // has no name/title/projectId, so retain its version separately instead of
    // inventing a partial domain row that could later be resurrected by replay.
    final tombstoneKey = 'remoteTombstone:${event['entityType']}:$id';
    final tombstone = await (database.select(
      database.syncMetadata,
    )..where((row) => row.key.equals(tombstoneKey))).getSingleOrNull();
    final deletedVersion = int.tryParse(tombstone?.value ?? '') ?? 0;
    if (version <= deletedVersion ||
        version <= (existing?.read<int>('remote_version') ?? 0)) {
      return;
    }
    if (existing != null && existing.read<String>('sync_status') != 'synced') {
      throw const _RemoteMutationConflict();
    }
    if (event['operation'] == 'delete') {
      final deletedAt = event['createdAt'] as String;
      await database.customUpdate(
        'UPDATE ${table.actualTableName} SET deleted_at = ?, updated_at = ?, '
        'version = ?, remote_version = ?, sync_status = ? WHERE id = ?',
        variables: [
          Variable<String>(deletedAt),
          Variable<String>(deletedAt),
          Variable<int>(version),
          Variable<int>(version),
          const Variable<String>('synced'),
          Variable<String>(id),
        ],
        updates: {table},
      );
      await database
          .into(database.syncMetadata)
          .insertOnConflictUpdate(
            SyncMetadataCompanion.insert(key: tombstoneKey, value: '$version'),
          );
      return;
    }
    final value =
        jsonDecode(event['payloadJson'] as String) as Map<String, dynamic>;
    if (isProject) {
      final status = value['status'] as String;
      if (!const {'active', 'completed', 'archived'}.contains(status)) {
        throw const FormatException('invalid project status');
      }
      await database
          .into(database.projects)
          .insertOnConflictUpdate(
            ProjectsCompanion.insert(
              manualPosition: Value((value['manualPosition'] as num?)?.toInt()),
              id: id,
              name: value['name'] as String,
              goal: Value(value['goal'] as String?),
              description: Value(value['description'] as String?),
              color: Value(value['color'] as String?),
              status: Value(status),
              startDate: Value(value['startDate'] as String?),
              due: Value(value['due'] as String?),
              nextActionTaskId: Value(value['nextActionTaskId'] as String?),
              createdAt: value['createdAt'] as String,
              updatedAt: value['updatedAt'] as String,
              version: Value(version),
              remoteVersion: Value(version),
              deletedAt: const Value(null),
              syncStatus: const Value('synced'),
            ),
          );
    } else {
      final projectId = value['projectId'] as String;
      final previous = await (database.select(
        database.projectMilestones,
      )..where((row) => row.id.equals(id))).getSingleOrNull();
      if (previous != null && previous.projectId != projectId) {
        throw const FormatException('milestone projectId is immutable');
      }
      await database
          .into(database.projectMilestones)
          .insertOnConflictUpdate(
            ProjectMilestonesCompanion.insert(
              id: id,
              projectId: projectId,
              title: value['title'] as String,
              due: Value(value['due'] as String?),
              completed: Value(value['completed'] as bool),
              completedAt: Value(value['completedAt'] as String?),
              position: Value(
                _nonNegativeInt(value['position'], 'milestone position'),
              ),
              createdAt: value['createdAt'] as String,
              updatedAt: value['updatedAt'] as String,
              version: Value(version),
              remoteVersion: Value(version),
              deletedAt: Value(value['deletedAt'] as String?),
              syncStatus: const Value('synced'),
            ),
          );
    }
  }
}
