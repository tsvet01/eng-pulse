// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'cached_summary.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class CachedSummaryAdapter extends TypeAdapter<CachedSummary> {
  @override
  final int typeId = 0;

  @override
  CachedSummary read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return CachedSummary(
      date: fields[0] as String,
      url: fields[1] as String,
      title: fields[2] as String,
      summarySnippet: fields[3] as String,
      cachedContent: fields[4] as String?,
      lastUpdated: fields[5] as DateTime?,
      originalUrl: fields[6] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, CachedSummary obj) {
    writer
      ..writeByte(7)
      ..writeByte(0)
      ..write(obj.date)
      ..writeByte(1)
      ..write(obj.url)
      ..writeByte(2)
      ..write(obj.title)
      ..writeByte(3)
      ..write(obj.summarySnippet)
      ..writeByte(4)
      ..write(obj.cachedContent)
      ..writeByte(5)
      ..write(obj.lastUpdated)
      ..writeByte(6)
      ..write(obj.originalUrl);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CachedSummaryAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
