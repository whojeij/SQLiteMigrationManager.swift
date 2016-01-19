import Foundation
import SQLite

struct MigrationDB {
  static let table = Table("schema_migrations")
  static let version = Expression<Int64>("version")
}

public struct SQLiteMigrationManager {
  private let db: Connection

  public let migrations: [Migration]

  public init(db: Connection, migrations: [Migration] = [], bundle: NSBundle? = nil) {
    self.db = db
    self.migrations = [
      bundle?.migrations() ?? [],
      migrations
    ].flatten().sort { $0.version < $1.version }
  }

  public func hasMigrationsTable() -> Bool {
    let sqliteMaster = Table("sqlite_master")
    let type = Expression<String>("type")
    let name = Expression<String>("name")

    return db.scalar(sqliteMaster.filter(type == "table" && name == "schema_migrations").count) == 1;
  }

  public func createMigrationsTable() throws {
    try db.run(MigrationDB.table.create(ifNotExists: true) { table in
      table.column(MigrationDB.version, unique: true)
    })
  }

  public func currentVersion() -> Int64 {
    if !hasMigrationsTable() {
      return 0
    }

    return db.scalar(MigrationDB.table.select(MigrationDB.version.max)) ?? 0
  }

  public func originVersion() -> Int64 {
    if !hasMigrationsTable() {
      return 0
    }

    return db.scalar(MigrationDB.table.select(MigrationDB.version.min)) ?? 0
  }

  public func appliedVersions() -> [Int64] {
    do {
      var versions = [Int64]()
      try db.prepare(MigrationDB.table.select(MigrationDB.version).order(MigrationDB.version)).forEach {
        versions.append($0[MigrationDB.version])
      }
      return versions
    } catch {
      return []
    }
  }

  public func pendingMigrations() -> [Migration] {
    if !hasMigrationsTable() {
      return migrations
    }

    let versions = appliedVersions()
    return migrations.filter { migration in
      !versions.contains(migration.version)
    }
  }

  public func needsMigration() -> Bool {
    if !hasMigrationsTable() {
      return false
    }

    return pendingMigrations().count > 0
  }

  public func migrateDatabase(toVersion toVersion: Int64 = Int64.max) throws {
    try pendingMigrations().filter { $0.version <= toVersion }.forEach { migration in
      try db.transaction {
        try migration.migrateDatabase(self.db)
        try self.db.run(MigrationDB.table.insert(MigrationDB.version <- migration.version))
      }
    }
  }
}

extension NSBundle {
  private func migrations() -> [Migration] {
    let regex = try! NSRegularExpression(pattern: "^(\\d+)_([\\w\\s-]+)\\.sql$", options: .CaseInsensitive)

    return URLsForResourcesWithExtension("sql", subdirectory: nil)?.filter {
      url in
      if let fileName = url.lastPathComponent,
      let result = regex.firstMatchInString(fileName, options: .ReportProgress, range: NSMakeRange(0, fileName.startIndex.distanceTo(fileName.endIndex))) {
        return result.numberOfRanges == 3
      } else {
        return false
      }
    }.map {
      return FileMigration(url: $0)!
    } ?? []
  }
}

public protocol Migration: CustomStringConvertible {
  var version: Int64 { get }

  func migrateDatabase(db: Connection) throws
}

public extension Migration {
  var description: String {
    return "Migration(\(version))"
  }
}

public struct FileMigration: Migration {
  public let version: Int64
  public let url: NSURL

  public func migrateDatabase(db: Connection) throws {
    let fileContents = try NSString(contentsOfURL: url, encoding: NSUTF8StringEncoding)
    try db.execute(fileContents as String)
  }
}

extension FileMigration {
  public init?(url: NSURL) {
    guard let fileName = url.lastPathComponent else {
      return nil
    }
    guard let firstUndercoreRange = fileName.rangeOfString("_", options: .CaseInsensitiveSearch) else {
      return nil
    }
    guard let version = Int64(fileName.substringToIndex(firstUndercoreRange.startIndex)) else {
      return nil
    }

    self.version = version
    self.url = url
  }
}

extension FileMigration: CustomStringConvertible {
  public var description: String {
    return "FileMigration(\(version), \(url))"
  }
}
