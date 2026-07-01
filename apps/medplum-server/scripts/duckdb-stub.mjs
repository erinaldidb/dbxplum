// Optional DuckDB dependency stubbed for self-contained server bundles.
export class DuckDBInstance {
  static async create() {
    throw new Error('DuckDB is not available in this deployment bundle');
  }
}
