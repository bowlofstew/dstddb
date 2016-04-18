module std.database.postgres.database;
pragma(lib, "pq");
pragma(lib, "pgtypes");

import std.string;
import core.stdc.stdlib;

import std.database.postgres.bindings;
import std.database.common;
import std.database.exception;
import std.database.resolver;
import std.database.allocator;
import std.container.array;
import std.experimental.logger;
import std.database.impl;

import std.stdio;
import std.typecons;
import std.datetime;

struct DefaultPolicy {
    alias Allocator = MyMallocator;
}

alias Database(T) = BasicDatabase!(DatabaseImpl!T);
alias Connection(T) = BasicConnection!(ConnectionImpl!T);
alias Statement(T) = BasicStatement!(StatementImpl!T);
alias Result(T) = BasicResult!(ResultImpl!T);
alias ResultRange(T) = BasicResultRange!(Result!T);
alias Row(T) = BasicRow!(ResultImpl!T);
alias Value(T) = BasicValue!(ResultImpl!T);

auto createDatabase()(string defaultURI="") {
    return Database!DefaultPolicy(defaultURI);  
}

auto createDatabase(T)(string defaultURI="") {
    return Database!T(defaultURI);  
}

struct DatabaseImpl(T) {
    alias Allocator = T.Allocator;
    alias Connection = .ConnectionImpl!T;
    static const auto queryVariableType = QueryVariableType.Dollar;

    Allocator allocator;
    string defaultURI;

    this(string defaultURI_) {
        allocator = Allocator();
        defaultURI = defaultURI_;
    }

    ~this() {
    }

    bool bindable() {return true;}
    bool dateBinding() {return true;}
    bool poolEnable() {return false;}
}

struct ConnectionImpl(T) {
    alias Database = .DatabaseImpl!T;
    alias Statement = .StatementImpl!T;
    alias Allocator = T.Allocator;

    Database* db;
    string source;
    PGconn *con;

    this(Database* db_, string source_) {
        db = db_;
        source = source_.length == 0 ? db.defaultURI : source_;

        Source src = resolve(source);
        string conninfo;
        conninfo ~= "dbname=" ~ src.database;
        con = PQconnectdb(toStringz(conninfo));
        if (PQstatus(con) != CONNECTION_OK) error("login error");
    }

    void error(string msg) {
        import std.conv;
        auto s = msg ~ to!string(PQerrorMessage(con));
        throw new DatabaseException(msg);
    }

    ~this() {
        PQfinish(con);
    }
}


struct StatementImpl(T) {
    alias Allocator = T.Allocator;
    alias Connection = .ConnectionImpl!T;
    alias Bind = .Bind!T;
    alias Result = .ResultImpl!T;

    Connection* connection;
    string sql;
    Allocator *allocator;
    PGconn *con;
    string name;
    PGresult *prepareRes;
    PGresult *res;

    Array!(char*) bindValue;
    Array!(Oid) bindType;
    Array!(int) bindLength;
    Array!(int) bindFormat;

    this(Connection* connection_, string sql_) {
        connection = connection_;
        sql = sql_;
        allocator = &connection.db.allocator;
        con = connection.con;
        //prepare();
    }

    ~this() {
        for(int i = 0; i != bindValue.length; ++i) {
            auto ptr = bindValue[i];
            auto length = bindLength[i];
            allocator.deallocate(ptr[0..length]);
        }
    }

    void bind(int n, int value) {
    }

    void bind(int n, const char[] value) {
    }

    void query() {
        info("query sql: ", sql);

        if (1) {
            if (!prepareRes) prepare();

            auto n = bindValue.length;
            int resultFormat = 1;

            res = PQexecPrepared(
                    con,
                    toStringz(name),
                    cast(int) n,
                    n ? cast(const char **) &bindValue[0] : null,
                    n ? cast(int*) &bindLength[0] : null,
                    n ? cast(int*) &bindFormat[0] : null,
                    resultFormat);

        } else {
            if (!PQsendQuery(con, toStringz(sql))) throw error("PQsendQuery");
            res = PQgetResult(con);
        }

        // problem with PQsetSingleRowMode and prepared statements
        // if (!PQsetSingleRowMode(con)) throw error("PQsetSingleRowMode");
    }

    void query(X...) (X args) {
        info("query sql: ", sql);

        // todo: stack allocation

        bindValue.clear();
        bindType.clear();
        bindLength.clear();
        bindFormat.clear();

        foreach (ref arg; args) bind(arg);

        auto n = bindValue.length;

        /*
           types must be set in prepared
           res = PQexecPrepared(
           con,
           toStringz(name),
           cast(int) n,
           n ? cast(const char **) &bindValue[0] : null,
           n ? cast(int*) &bindLength[0] : null,
           n ? cast(int*) &bindFormat[0] : null,
           0);
         */

        int resultForamt = 0;

        res = PQexecParams(
                con,
                toStringz(sql),
                cast(int) n,
                n ? cast(Oid*) &bindType[0] : null,
                n ? cast(const char **) &bindValue[0] : null,
                n ? cast(int*) &bindLength[0] : null,
                n ? cast(int*) &bindFormat[0] : null,
                resultForamt);
    }

    int binds() {return cast(int) bindValue.length;} // fix

    void bind(string v) {
        import core.stdc.string: strncpy;
        void[] s = allocator.allocate(v.length+1);
        char *p = cast(char*) s.ptr;
        strncpy(p, v.ptr, v.length);
        p[v.length] = 0;
        bindValue ~= p;
        bindType ~= 0;
        bindLength ~= 0;
        bindFormat ~= 0;
    }

    void bind(int v) {
        import std.bitmanip;
        void[] s = allocator.allocate(int.sizeof);
        *cast(int*) s.ptr = peek!(int, Endian.bigEndian)(cast(ubyte[]) (&v)[0..int.sizeof]);
        bindValue ~= cast(char*) s.ptr;
        bindType ~= INT4OID;
        bindLength ~= cast(int) s.length;
        bindFormat ~= 1;
    }

    void bind(Date v) {
        /* utility functions take 8 byte values but DATEOID is a 4 byte value */
        import std.bitmanip;
        int[3] mdy;
        mdy[0] = v.month;
        mdy[1] = v.day;
        mdy[2] = v.year;
        long d;
        PGTYPESdate_mdyjul(&mdy[0], &d);
        void[] s = allocator.allocate(4);
        *cast(int*) s.ptr = peek!(int, Endian.bigEndian)(cast(ubyte[]) (&d)[0..4]);
        bindValue ~= cast(char*) s.ptr;
        bindType ~= DATEOID;
        bindLength ~= cast(int) s.length;
        bindFormat ~= 1;
    }

    void prepare()  {
        const Oid* paramTypes;
        prepareRes = PQprepare(
                con,
                toStringz(name),
                toStringz(sql),
                0,
                paramTypes);
    }

    auto error(string msg) {
        import std.conv;
        string s;
        s ~= msg ~ ", " ~ to!string(PQerrorMessage(con));
        return new DatabaseException(s);
    }

    void reset() {
    }
}

struct Describe(T) {
    int dbType;
    int fmt;
}


struct Bind(T) {
    ValueType type;
    int idx;
    //int fmt;
    //int len;
    //int isNull; 
}

struct ResultImpl(T) {
    alias Allocator = T.Allocator;
    alias Describe = .Describe!T;
    alias Statement = .StatementImpl!T;
    alias Bind = .Bind!T;

    Statement* stmt;
    PGconn *con;
    PGresult *res;
    int columns;
    Array!Describe describe;
    ExecStatusType status;
    int row;
    int rows;

    // artifical bind array (for now)
    Array!Bind bind;

    this(Statement* stmt_) {
        stmt = stmt_;
        con = stmt.con;
        res = stmt.res;

        if (!setup()) return;
        build_describe();
        build_bind();
    }

    ~this() {
        if (res) close();
    }

    bool setup() {
        if (!res) {
            info("no result");
            return false;
        }
        status = PQresultStatus(res);
        rows = PQntuples(res);

        // not handling PGRESS_SINGLE_TUPLE yet
        if (status == PGRES_COMMAND_OK) {
            close();
            return false;
        } else if (status == PGRES_EMPTY_QUERY) {
            close();
            return false;
        } else if (status == PGRES_TUPLES_OK) {
            return true;
        } else throw error(res,status);
    }


    void build_describe() {
        // called after next()
        columns = PQnfields(res);
        for (int col = 0; col != columns; col++) {
            describe ~= Describe();
            auto d = &describe.back();
            d.dbType = cast(int) PQftype(res, col);
            d.fmt = PQfformat(res, col);
        }
    }

    void build_bind() {
        // artificial bind setup
        bind.reserve(columns);
        for(int i = 0; i < columns; ++i) {
            auto d = &describe[i];
            bind ~= Bind();
            auto b = &bind.back();
            b.type = ValueType.String;
            b.idx = i;
            switch(d.dbType) {
                case VARCHAROID: b.type = ValueType.String; break;
                case INT4OID: b.type = ValueType.Int; break;
                case DATEOID: b.type = ValueType.Date; break;
                default: throw new DatabaseException("unsupported type");
            }
        }
    }

    //bool start() {return data_.status == PGRES_SINGLE_TUPLE;}
    bool start() {return row != rows;}

    bool next() {
        return ++row != rows;
    }

    bool singleRownext() {
        if (res) PQclear(res);
        res = PQgetResult(con);
        if (!res) return false;
        status = PQresultStatus(res);

        if (status == PGRES_COMMAND_OK) {
            close();
            return false;
        } else if (status == PGRES_SINGLE_TUPLE) return true;
        else if (status == PGRES_TUPLES_OK) {
            close();
            return false;
        } else throw error(status);
    }

    void close() {
        if (!res) throw error("couldn't close result: result was not open");
        res = PQgetResult(con);
        if (res) throw error("couldn't close result: was not finished");
        res = null;
    }

    auto error(string msg) {
        return new DatabaseException(msg);
    }

    auto error(ExecStatusType status) {
        import std.conv;
        string s = "result error: " ~ to!string(PQresStatus(status));
        return new DatabaseException(s);
    }

    auto error(PGresult *res, ExecStatusType status) {
        import std.conv;
        const char* msg = PQresultErrorMessage(res);
        string s =
            "error: " ~ to!string(PQresStatus(status)) ~
            ", message:" ~ to!string(msg);
        return new DatabaseException(s);
    }

    /*
       char[] get(X:char[])(Bind *b) {
       auto ptr = cast(char*) b.data.ptr;
       return ptr[0..b.length];
       }
     */

    auto get(X:string)(Bind *b) {
        checkType(type(b.idx),VARCHAROID);
        immutable char *ptr = cast(immutable char*) data(b.idx);
        return cast(string) ptr[0..len(b.idx)];
    }

    auto get(X:int)(Bind *b) {
        import std.bitmanip;
        checkType(type(b.idx),INT4OID);
        auto p = cast(ubyte*) data(b.idx);
        return bigEndianToNative!int(p[0..int.sizeof]);
    }

    auto get(X:Date)(Bind *b) {
        import std.bitmanip;
        checkType(type(b.idx),DATEOID);
        auto ptr = cast(ubyte*) data(b.idx);
        int sz = len(b.idx);
        date d = bigEndianToNative!uint(ptr[0..4]); // why not sz?
        int[3] mdy;
        PGTYPESdate_julmdy(d, &mdy[0]);
        return Date(mdy[2],mdy[0],mdy[1]);
    }

    void checkType(int a, int b) {
        if (a != b) throw new DatabaseException("type mismatch");
    }

    void* data(int col) {return PQgetvalue(res, row, col);}
    bool isNull(int col) {return PQgetisnull(res, row, col) != 0;}
    int type(int col) {return describe[col].dbType;}
    int fmt(int col) {return describe[col].fmt;}
    int len(int col) {return PQgetlength(res, row, col);}

}
