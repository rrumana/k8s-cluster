#include <QByteArray>
#include <QCommandLineOption>
#include <QCommandLineParser>
#include <QCoreApplication>
#include <QFile>
#include <QFileInfo>
#include <QSettings>
#include <QString>
#include <QTextStream>
#include <QUrl>
#include <QUrlQuery>
#include <QVariantHash>

#include <sqlite3.h>

#include <cstdint>
#include <limits>
#include <map>
#include <memory>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace
{
    class Error : public std::runtime_error
    {
    public:
        using std::runtime_error::runtime_error;
    };

    [[noreturn]] void fail(const QString &message)
    {
        throw Error(message.toStdString());
    }

    struct BValue
    {
        enum class Type
        {
            Integer,
            String,
            List,
            Dictionary
        };

        Type type = Type::String;
        qint64 integer = 0;
        QByteArray string;
        std::vector<BValue> list;
        std::map<QByteArray, BValue> dictionary;
    };

    class BencodeParser
    {
    public:
        explicit BencodeParser(QByteArray data)
            : m_data(std::move(data))
        {
        }

        BValue parse()
        {
            BValue value = parseValue();
            if (m_position != m_data.size())
                fail(QStringLiteral("Trailing bytes in bencoded resume data"));
            return value;
        }

    private:
        char current() const
        {
            if (m_position >= m_data.size())
                fail(QStringLiteral("Unexpected end of bencoded resume data"));
            return m_data.at(m_position);
        }

        BValue parseValue()
        {
            switch (current())
            {
            case 'i':
                return parseInteger();
            case 'l':
                return parseList();
            case 'd':
                return parseDictionary();
            default:
                if ((current() >= '0') && (current() <= '9'))
                    return parseString();
                fail(QStringLiteral("Invalid bencode token at byte %1").arg(m_position));
            }
        }

        BValue parseInteger()
        {
            ++m_position;
            const qsizetype start = m_position;
            while (current() != 'e')
                ++m_position;

            const QByteArray encoded = m_data.mid(start, m_position - start);
            ++m_position;
            bool ok = false;
            const qint64 value = encoded.toLongLong(&ok);
            if (!ok || encoded.isEmpty())
                fail(QStringLiteral("Invalid bencoded integer"));

            BValue result;
            result.type = BValue::Type::Integer;
            result.integer = value;
            return result;
        }

        BValue parseString()
        {
            const qsizetype start = m_position;
            while (current() != ':')
            {
                if ((current() < '0') || (current() > '9'))
                    fail(QStringLiteral("Invalid bencoded string length"));
                ++m_position;
            }

            const QByteArray encodedLength = m_data.mid(start, m_position - start);
            ++m_position;
            bool ok = false;
            const qlonglong length = encodedLength.toLongLong(&ok);
            if (!ok || (length < 0) || (length > (m_data.size() - m_position)))
                fail(QStringLiteral("Invalid bencoded string payload length"));

            BValue result;
            result.type = BValue::Type::String;
            result.string = m_data.mid(m_position, length);
            m_position += length;
            return result;
        }

        BValue parseList()
        {
            ++m_position;
            BValue result;
            result.type = BValue::Type::List;
            while (current() != 'e')
                result.list.push_back(parseValue());
            ++m_position;
            return result;
        }

        BValue parseDictionary()
        {
            ++m_position;
            BValue result;
            result.type = BValue::Type::Dictionary;
            while (current() != 'e')
            {
                BValue key = parseString();
                if (result.dictionary.contains(key.string))
                    fail(QStringLiteral("Duplicate bencoded dictionary key"));
                result.dictionary.emplace(std::move(key.string), parseValue());
            }
            ++m_position;
            return result;
        }

        QByteArray m_data;
        qsizetype m_position = 0;
    };

    void encodeValue(const BValue &value, QByteArray &output)
    {
        switch (value.type)
        {
        case BValue::Type::Integer:
            output.append('i');
            output.append(QByteArray::number(value.integer));
            output.append('e');
            break;
        case BValue::Type::String:
            output.append(QByteArray::number(value.string.size()));
            output.append(':');
            output.append(value.string);
            break;
        case BValue::Type::List:
            output.append('l');
            for (const BValue &item : value.list)
                encodeValue(item, output);
            output.append('e');
            break;
        case BValue::Type::Dictionary:
            output.append('d');
            for (const auto &[key, item] : value.dictionary)
            {
                output.append(QByteArray::number(key.size()));
                output.append(':');
                output.append(key);
                encodeValue(item, output);
            }
            output.append('e');
            break;
        }
    }

    QByteArray encode(const BValue &value)
    {
        QByteArray result;
        encodeValue(value, result);
        return result;
    }

    qint64 integerValue(const BValue &root, const QByteArray &key)
    {
        const auto item = root.dictionary.find(key);
        if ((item == root.dictionary.end()) || (item->second.type != BValue::Type::Integer))
            fail(QStringLiteral("Missing integer resume-data key: %1").arg(QString::fromLatin1(key)));
        return item->second.integer;
    }

    void setInteger(BValue &root, const QByteArray &key, const qint64 value)
    {
        auto item = root.dictionary.find(key);
        if ((item == root.dictionary.end()) || (item->second.type != BValue::Type::Integer))
            fail(QStringLiteral("Missing integer resume-data key: %1").arg(QString::fromLatin1(key)));
        item->second.integer = value;
    }

    bool hasInteger(const BValue &root, const QByteArray &key)
    {
        const auto item = root.dictionary.find(key);
        return (item != root.dictionary.end()) && (item->second.type == BValue::Type::Integer);
    }

    qint64 checkedSum(const qint64 left, const qint64 right, const QByteArray &key)
    {
        if ((right > 0) && (left > (std::numeric_limits<qint64>::max() - right)))
            fail(QStringLiteral("Integer overflow while merging %1").arg(QString::fromLatin1(key)));
        if ((right < 0) && (left < (std::numeric_limits<qint64>::min() - right)))
            fail(QStringLiteral("Integer underflow while merging %1").arg(QString::fromLatin1(key)));
        return left + right;
    }

    void mergeSum(BValue &target, const BValue &source, const QByteArray &key)
    {
        setInteger(target, key, checkedSum(integerValue(target, key), integerValue(source, key), key));
    }

    void mergeMaximum(BValue &target, const BValue &source, const QByteArray &key)
    {
        if (!hasInteger(target, key) || !hasInteger(source, key))
            return;
        setInteger(target, key, std::max(integerValue(target, key), integerValue(source, key)));
    }

    void mergeMinimumNonZero(BValue &target, const BValue &source, const QByteArray &key)
    {
        if (!hasInteger(target, key) || !hasInteger(source, key))
            return;
        const qint64 targetValue = integerValue(target, key);
        const qint64 sourceValue = integerValue(source, key);
        if (targetValue == 0)
            setInteger(target, key, sourceValue);
        else if ((sourceValue != 0) && (sourceValue < targetValue))
            setInteger(target, key, sourceValue);
    }

    void mergeResumeData(BValue &target, const BValue &source)
    {
        if ((target.type != BValue::Type::Dictionary) || (source.type != BValue::Type::Dictionary))
            fail(QStringLiteral("Resume data root is not a dictionary"));

        mergeSum(target, source, QByteArrayLiteral("total_uploaded"));
        mergeSum(target, source, QByteArrayLiteral("total_downloaded"));

        for (const QByteArray &key : {QByteArrayLiteral("active_time"), QByteArrayLiteral("finished_time")
            , QByteArrayLiteral("seeding_time"), QByteArrayLiteral("last_upload")
            , QByteArrayLiteral("last_download"), QByteArrayLiteral("last_seen_complete")})
        {
            mergeMaximum(target, source, key);
        }

        for (const QByteArray &key : {QByteArrayLiteral("added_time"), QByteArrayLiteral("completed_time")})
            mergeMinimumNonZero(target, source, key);
    }

    struct SqliteCloser
    {
        void operator()(sqlite3 *database) const
        {
            if (database)
                sqlite3_close(database);
        }
    };

    struct StatementCloser
    {
        void operator()(sqlite3_stmt *statement) const
        {
            if (statement)
                sqlite3_finalize(statement);
        }
    };

    using Database = std::unique_ptr<sqlite3, SqliteCloser>;
    using Statement = std::unique_ptr<sqlite3_stmt, StatementCloser>;

    Database openDatabase(const QString &path, const int flags)
    {
        sqlite3 *raw = nullptr;
        const QByteArray encodedPath = QFile::encodeName(path);
        const int result = sqlite3_open_v2(encodedPath.constData(), &raw, flags, nullptr);
        Database database(raw);
        if (result != SQLITE_OK)
            fail(QStringLiteral("Cannot open SQLite database %1: %2").arg(path, QString::fromUtf8(sqlite3_errmsg(raw))));
        return database;
    }

    Database openImmutableDatabase(const QString &path)
    {
        QUrl uri = QUrl::fromLocalFile(QFileInfo(path).absoluteFilePath());
        QUrlQuery query;
        query.addQueryItem(QStringLiteral("mode"), QStringLiteral("ro"));
        query.addQueryItem(QStringLiteral("immutable"), QStringLiteral("1"));
        uri.setQuery(query);

        sqlite3 *raw = nullptr;
        const QByteArray encodedUri = uri.toEncoded(QUrl::FullyEncoded);
        const int result = sqlite3_open_v2(encodedUri.constData(), &raw
            , SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nullptr);
        Database database(raw);
        if (result != SQLITE_OK)
            fail(QStringLiteral("Cannot open immutable SQLite database %1: %2")
                .arg(path, QString::fromUtf8(sqlite3_errmsg(raw))));
        return database;
    }

    void execute(sqlite3 *database, const char *sql)
    {
        char *error = nullptr;
        if (sqlite3_exec(database, sql, nullptr, nullptr, &error) != SQLITE_OK)
        {
            const QString message = QString::fromUtf8(error ? error : "unknown SQLite error");
            sqlite3_free(error);
            fail(message);
        }
    }

    Statement prepare(sqlite3 *database, const char *sql)
    {
        sqlite3_stmt *raw = nullptr;
        if (sqlite3_prepare_v2(database, sql, -1, &raw, nullptr) != SQLITE_OK)
            fail(QString::fromUtf8(sqlite3_errmsg(database)));
        return Statement(raw);
    }

    qint64 scalarInteger(sqlite3 *database, const char *sql)
    {
        Statement statement = prepare(database, sql);
        if (sqlite3_step(statement.get()) != SQLITE_ROW)
            fail(QString::fromUtf8(sqlite3_errmsg(database)));
        return sqlite3_column_int64(statement.get(), 0);
    }

    void verifyDatabase(sqlite3 *database, const QString &label)
    {
        Statement statement = prepare(database, "PRAGMA quick_check");
        if (sqlite3_step(statement.get()) != SQLITE_ROW)
            fail(QStringLiteral("Cannot check %1 database").arg(label));
        const QString result = QString::fromUtf8(reinterpret_cast<const char *>(sqlite3_column_text(statement.get(), 0)));
        if (result != QStringLiteral("ok"))
            fail(QStringLiteral("%1 database failed quick_check: %2").arg(label, result));
    }

    struct TorrentTotals
    {
        qint64 uploaded = 0;
        qint64 downloaded = 0;
        qint64 count = 0;
    };

    struct TorrentMergeTotals
    {
        TorrentTotals target;
        TorrentTotals source;
        TorrentTotals merged;
    };

    void makeOwnerWritable(const QString &path)
    {
        QFile file(path);
        if (!file.setPermissions(file.permissions() | QFileDevice::WriteOwner))
            fail(QStringLiteral("Cannot make new output writable: %1").arg(path));
    }

    TorrentMergeTotals mergeTorrentDatabases(const QString &targetPath, const QString &sourcePath, const QString &outputPath)
    {
        if (!QFile::copy(targetPath, outputPath))
            fail(QStringLiteral("Cannot copy target database to %1").arg(outputPath));
        makeOwnerWritable(outputPath);

        Database source = openImmutableDatabase(sourcePath);
        Database output = openDatabase(outputPath, SQLITE_OPEN_READWRITE);
        verifyDatabase(source.get(), QStringLiteral("source"));
        verifyDatabase(output.get(), QStringLiteral("target"));

        const qint64 sourceCount = scalarInteger(source.get(), "SELECT COUNT(*) FROM torrents");
        const qint64 targetCount = scalarInteger(output.get(), "SELECT COUNT(*) FROM torrents");
        if (sourceCount != targetCount)
            fail(QStringLiteral("Torrent counts differ: target=%1 source=%2").arg(targetCount).arg(sourceCount));

        Statement targets = prepare(output.get()
            , "SELECT id, torrent_id, libtorrent_resume_data FROM torrents ORDER BY id");
        Statement sourceById = prepare(source.get()
            , "SELECT libtorrent_resume_data FROM torrents WHERE torrent_id = ?1");
        Statement update = prepare(output.get()
            , "UPDATE torrents SET libtorrent_resume_data = ?1 WHERE id = ?2");

        TorrentMergeTotals totals;
        execute(output.get(), "BEGIN IMMEDIATE");
        try
        {
            while (sqlite3_step(targets.get()) == SQLITE_ROW)
            {
                const qint64 rowId = sqlite3_column_int64(targets.get(), 0);
                const int torrentIdType = sqlite3_column_type(targets.get(), 1);
                const void *torrentId = sqlite3_column_blob(targets.get(), 1);
                const int torrentIdSize = sqlite3_column_bytes(targets.get(), 1);
                const void *targetBlob = sqlite3_column_blob(targets.get(), 2);
                const int targetBlobSize = sqlite3_column_bytes(targets.get(), 2);

                sqlite3_reset(sourceById.get());
                sqlite3_clear_bindings(sourceById.get());
                if (torrentIdType == SQLITE_TEXT)
                    sqlite3_bind_text(sourceById.get(), 1, static_cast<const char *>(torrentId), torrentIdSize, SQLITE_TRANSIENT);
                else
                    sqlite3_bind_blob(sourceById.get(), 1, torrentId, torrentIdSize, SQLITE_TRANSIENT);
                if (sqlite3_step(sourceById.get()) != SQLITE_ROW)
                    fail(QStringLiteral("Source is missing a target torrent ID"));

                const void *sourceBlob = sqlite3_column_blob(sourceById.get(), 0);
                const int sourceBlobSize = sqlite3_column_bytes(sourceById.get(), 0);
                BValue target = BencodeParser(QByteArray(static_cast<const char *>(targetBlob), targetBlobSize)).parse();
                const BValue sourceValue = BencodeParser(QByteArray(static_cast<const char *>(sourceBlob), sourceBlobSize)).parse();
                totals.target.uploaded = checkedSum(totals.target.uploaded
                    , integerValue(target, QByteArrayLiteral("total_uploaded")), QByteArrayLiteral("target total_uploaded"));
                totals.target.downloaded = checkedSum(totals.target.downloaded
                    , integerValue(target, QByteArrayLiteral("total_downloaded")), QByteArrayLiteral("target total_downloaded"));
                totals.source.uploaded = checkedSum(totals.source.uploaded
                    , integerValue(sourceValue, QByteArrayLiteral("total_uploaded")), QByteArrayLiteral("source total_uploaded"));
                totals.source.downloaded = checkedSum(totals.source.downloaded
                    , integerValue(sourceValue, QByteArrayLiteral("total_downloaded")), QByteArrayLiteral("source total_downloaded"));
                mergeResumeData(target, sourceValue);

                totals.merged.uploaded = checkedSum(totals.merged.uploaded
                    , integerValue(target, QByteArrayLiteral("total_uploaded")), QByteArrayLiteral("aggregate total_uploaded"));
                totals.merged.downloaded = checkedSum(totals.merged.downloaded
                    , integerValue(target, QByteArrayLiteral("total_downloaded")), QByteArrayLiteral("aggregate total_downloaded"));
                ++totals.target.count;
                ++totals.source.count;
                ++totals.merged.count;

                const QByteArray merged = encode(target);
                sqlite3_reset(update.get());
                sqlite3_clear_bindings(update.get());
                sqlite3_bind_blob(update.get(), 1, merged.constData(), merged.size(), SQLITE_TRANSIENT);
                sqlite3_bind_int64(update.get(), 2, rowId);
                if (sqlite3_step(update.get()) != SQLITE_DONE)
                    fail(QString::fromUtf8(sqlite3_errmsg(output.get())));
            }
            execute(output.get(), "COMMIT");
        }
        catch (...)
        {
            execute(output.get(), "ROLLBACK");
            throw;
        }

        if (totals.merged.count != targetCount)
            fail(QStringLiteral("Did not merge every target torrent"));
        if ((totals.merged.uploaded != checkedSum(totals.target.uploaded, totals.source.uploaded
                , QByteArrayLiteral("per-torrent uploaded validation")))
            || (totals.merged.downloaded != checkedSum(totals.target.downloaded, totals.source.downloaded
                , QByteArrayLiteral("per-torrent downloaded validation"))))
        {
            fail(QStringLiteral("Merged per-torrent totals did not validate"));
        }
        verifyDatabase(output.get(), QStringLiteral("merged"));
        return totals;
    }

    qint64 statistic(const QVariantHash &statistics, const QString &key)
    {
        bool ok = false;
        const qint64 value = statistics.value(key).toLongLong(&ok);
        if (!ok)
            fail(QStringLiteral("Missing global statistic %1").arg(key));
        return value;
    }

    struct GlobalTotals
    {
        qint64 uploaded = 0;
        qint64 downloaded = 0;
    };

    struct GlobalMergeTotals
    {
        GlobalTotals target;
        GlobalTotals source;
        GlobalTotals merged;
    };

    GlobalMergeTotals mergeGlobalStatistics(const QString &targetPath, const QString &sourcePath, const QString &outputPath)
    {
        QSettings target(targetPath, QSettings::IniFormat);
        QSettings source(sourcePath, QSettings::IniFormat);
        const QVariantHash targetStats = target.value(QStringLiteral("Stats/AllStats")).toHash();
        const QVariantHash sourceStats = source.value(QStringLiteral("Stats/AllStats")).toHash();

        GlobalMergeTotals totals;
        totals.target.downloaded = statistic(targetStats, QStringLiteral("AlltimeDL"));
        totals.target.uploaded = statistic(targetStats, QStringLiteral("AlltimeUL"));
        totals.source.downloaded = statistic(sourceStats, QStringLiteral("AlltimeDL"));
        totals.source.uploaded = statistic(sourceStats, QStringLiteral("AlltimeUL"));
        totals.merged.downloaded = checkedSum(totals.target.downloaded, totals.source.downloaded
            , QByteArrayLiteral("AlltimeDL"));
        totals.merged.uploaded = checkedSum(totals.target.uploaded, totals.source.uploaded
            , QByteArrayLiteral("AlltimeUL"));

        if (!QFile::copy(targetPath, outputPath))
            fail(QStringLiteral("Cannot copy target statistics to %1").arg(outputPath));
        makeOwnerWritable(outputPath);

        QSettings output(outputPath, QSettings::IniFormat);
        QVariantHash merged = targetStats;
        merged.insert(QStringLiteral("AlltimeDL"), totals.merged.downloaded);
        merged.insert(QStringLiteral("AlltimeUL"), totals.merged.uploaded);
        output.setValue(QStringLiteral("Stats/AllStats"), merged);
        output.sync();
        if (output.status() != QSettings::NoError)
            fail(QStringLiteral("Cannot write merged global statistics"));

        QSettings validation(outputPath, QSettings::IniFormat);
        const QVariantHash validated = validation.value(QStringLiteral("Stats/AllStats")).toHash();
        if ((statistic(validated, QStringLiteral("AlltimeDL")) != totals.merged.downloaded)
            || (statistic(validated, QStringLiteral("AlltimeUL")) != totals.merged.uploaded))
        {
            fail(QStringLiteral("Merged global statistics did not validate"));
        }
        return totals;
    }

    QString requiredValue(const QCommandLineParser &parser, const QCommandLineOption &option)
    {
        const QString value = parser.value(option);
        if (value.isEmpty())
            fail(QStringLiteral("Missing required option --%1").arg(option.names().constFirst()));
        return QFileInfo(value).absoluteFilePath();
    }

    void requireInputFile(const QString &path)
    {
        const QFileInfo file(path);
        if (!file.isFile() || !file.isReadable())
            fail(QStringLiteral("Input is not a readable regular file: %1").arg(path));
    }

    void requireNewOutput(const QString &path)
    {
        if (QFileInfo::exists(path))
            fail(QStringLiteral("Output already exists: %1").arg(path));
    }
}

int main(int argc, char *argv[])
{
    QCoreApplication application(argc, argv);
    QCoreApplication::setApplicationName(QStringLiteral("qbittorrent-merge-history"));
    QCoreApplication::setApplicationVersion(QStringLiteral("1"));

    QCommandLineParser parser;
    parser.setApplicationDescription(QStringLiteral("Offline merger for duplicate qBittorrent history"));
    parser.addHelpOption();
    parser.addVersionOption();

    const QCommandLineOption targetDb(QStringLiteral("target-db"), QStringLiteral("Surviving torrents.db"), QStringLiteral("path"));
    const QCommandLineOption sourceDb(QStringLiteral("source-db"), QStringLiteral("Retiring torrents.db"), QStringLiteral("path"));
    const QCommandLineOption targetStats(QStringLiteral("target-stats"), QStringLiteral("Surviving qBittorrent-data.conf"), QStringLiteral("path"));
    const QCommandLineOption sourceStats(QStringLiteral("source-stats"), QStringLiteral("Retiring qBittorrent-data.conf"), QStringLiteral("path"));
    const QCommandLineOption outputDb(QStringLiteral("output-db"), QStringLiteral("New merged torrents.db"), QStringLiteral("path"));
    const QCommandLineOption outputStats(QStringLiteral("output-stats"), QStringLiteral("New merged qBittorrent-data.conf"), QStringLiteral("path"));
    parser.addOptions({targetDb, sourceDb, targetStats, sourceStats, outputDb, outputStats});
    parser.process(application);

    try
    {
        const QString targetDbPath = requiredValue(parser, targetDb);
        const QString sourceDbPath = requiredValue(parser, sourceDb);
        const QString targetStatsPath = requiredValue(parser, targetStats);
        const QString sourceStatsPath = requiredValue(parser, sourceStats);
        const QString outputDbPath = requiredValue(parser, outputDb);
        const QString outputStatsPath = requiredValue(parser, outputStats);

        for (const QString &path : {targetDbPath, sourceDbPath, targetStatsPath, sourceStatsPath})
            requireInputFile(path);
        requireNewOutput(outputDbPath);
        requireNewOutput(outputStatsPath);

        const TorrentMergeTotals torrentTotals = mergeTorrentDatabases(targetDbPath, sourceDbPath, outputDbPath);
        const GlobalMergeTotals globalTotals = mergeGlobalStatistics(targetStatsPath, sourceStatsPath, outputStatsPath);

        QTextStream output(stdout);
        output << "merged_torrents=" << torrentTotals.merged.count << '\n'
               << "target_per_torrent_uploaded=" << torrentTotals.target.uploaded << '\n'
               << "source_per_torrent_uploaded=" << torrentTotals.source.uploaded << '\n'
               << "merged_per_torrent_uploaded=" << torrentTotals.merged.uploaded << '\n'
               << "target_per_torrent_downloaded=" << torrentTotals.target.downloaded << '\n'
               << "source_per_torrent_downloaded=" << torrentTotals.source.downloaded << '\n'
               << "merged_per_torrent_downloaded=" << torrentTotals.merged.downloaded << '\n'
               << "target_alltime_uploaded=" << globalTotals.target.uploaded << '\n'
               << "source_alltime_uploaded=" << globalTotals.source.uploaded << '\n'
               << "merged_alltime_uploaded=" << globalTotals.merged.uploaded << '\n'
               << "target_alltime_downloaded=" << globalTotals.target.downloaded << '\n'
               << "source_alltime_downloaded=" << globalTotals.source.downloaded << '\n'
               << "merged_alltime_downloaded=" << globalTotals.merged.downloaded << '\n';
        return 0;
    }
    catch (const std::exception &error)
    {
        QTextStream(stderr) << "error: " << error.what() << '\n';
        return 1;
    }
}
