import { define } from "../../codegen/class-definitions";

export default [
  define({
    name: "MySQLSQLConnection",
    construct: true,
    finalize: true,
    hasPendingActivity: true,
    configurable: false,
    klass: {
      //   escapeString: {
      //     fn: "escapeString",
      //   },
      //   escapeIdentifier: {
      //     fn: "escapeIdentifier",
      //   },
    },
    JSType: "0b11101110",
    proto: {
      close: {
        fn: "doClose",
      },
      flush: {
        fn: "doFlush",
      },
      connected: {
        getter: "getConnected",
      },
      ref: {
        fn: "doRef",
      },
      unref: {
        fn: "doUnref",
      },
      query: {
        fn: "createQuery",
      },
    },
  }),
  define({
    name: "MySQLSQLQuery",
    construct: true,
    finalize: true,
    configurable: false,
    hasPendingActivity: true,
    JSType: "0b11101110",
    klass: {},
    proto: {
      run: {
        fn: "doRun",
        length: 2,
      },
      cancel: {
        fn: "doCancel",
        length: 0,
      },
      done: {
        fn: "doDone",
        length: 0,
      },
    },
    values: ["pendingValue", "columns", "binding"],
    estimatedSize: true,
  }),
];