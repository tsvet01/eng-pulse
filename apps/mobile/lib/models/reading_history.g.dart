// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'reading_history.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class ReadingHistoryItemAdapter extends TypeAdapter<ReadingHistoryItem> {
  @override
  final int typeId = 1;

  @override
  ReadingHistoryItem read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return ReadingHistoryItem(
      url: fields[0] as String,
      title: fields[1] as String,
      date: fields[2] as String,
      readAt: fields[3] as DateTime,
      feedback: fields[4] as int?,
    );
  }

  @override
  void write(BinaryWriter writer, ReadingHistoryItem obj) {
    writer
      ..writeByte(5)
      ..writeByte(0)
      ..write(obj.url)
      ..writeByte(1)
      ..write(obj.title)
      ..writeByte(2)
      ..write(obj.date)
      ..writeByte(3)
      ..write(obj.readAt)
      ..writeByte(4)
      ..write(obj.feedback);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ReadingHistoryItemAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class UserPreferencesAdapter extends TypeAdapter<UserPreferences> {
  @override
  final int typeId = 2;

  @override
  UserPreferences read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return UserPreferences(
      notificationsEnabled: fields[0] as bool,
      dailyBriefingEnabled: fields[1] as bool,
      preferredTime: fields[2] as String,
      preferredTopics: (fields[3] as List?)?.cast<String>(),
      selectedModel: fields[4] as String,
    );
  }

  @override
  void write(BinaryWriter writer, UserPreferences obj) {
    writer
      ..writeByte(5)
      ..writeByte(0)
      ..write(obj.notificationsEnabled)
      ..writeByte(1)
      ..write(obj.dailyBriefingEnabled)
      ..writeByte(2)
      ..write(obj.preferredTime)
      ..writeByte(3)
      ..write(obj.preferredTopics)
      ..writeByte(4)
      ..write(obj.selectedModel);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UserPreferencesAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
