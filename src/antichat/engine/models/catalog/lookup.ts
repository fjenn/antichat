import {
  Backend,
  Catalog,
  CatalogClass,
  CatalogFile,
  CatalogModel,
  DeviceClass,
  WeightsFile,
} from './types';

export function getModel(
  catalog: Catalog,
  id: string,
): CatalogModel | undefined {
  return catalog.models.find(m => m.id === id);
}

export function getClass(catalog: Catalog, id: DeviceClass): CatalogClass {
  // parseCatalog guarantees all five classes exist.
  return catalog.classes.find(c => c.id === id) as CatalogClass;
}

/** A model is revoked by id or by the hash of any of its files. */
export function isRevoked(catalog: Catalog, model: CatalogModel): boolean {
  const revoked = new Set(catalog.revoked);
  return (
    revoked.has(model.id) ||
    model.files.some(f => revoked.has(f.sha256)) ||
    (model.projector !== undefined && revoked.has(model.projector.sha256))
  );
}

/**
 * The weights file for a backend. A file that names the backend wins over one
 * that lists no backends; if nothing matches, the first file is used so a model
 * always has weights.
 */
export function weightsFor(model: CatalogModel, backend: Backend): WeightsFile {
  return (
    model.files.find(f => f.backends?.includes(backend)) ??
    model.files.find(f => f.backends === undefined) ??
    model.files[0]
  );
}

/** Direct download address of a catalogue file at its pinned revision. */
export function fileUrl(file: CatalogFile): string {
  const path = file.path.split('/').map(encodeURIComponent).join('/');
  return `https://huggingface.co/${file.repo}/resolve/${file.revision}/${path}`;
}

/** Stable local file name: unique across repositories that reuse a name. */
export function localFileName(file: CatalogFile): string {
  const repo = file.repo.replace('/', '__');
  return `${repo}__${file.path.replace(/\//g, '__')}`;
}

/** The files a model needs on disk for a backend, with or without vision. */
export function filesFor(
  model: CatalogModel,
  backend: Backend,
  vision: boolean,
): CatalogFile[] {
  const files: CatalogFile[] = [weightsFor(model, backend)];
  if (vision && model.projector) {
    files.push(model.projector);
  }
  return files;
}

export const totalBytes = (files: CatalogFile[]): number =>
  files.reduce((sum, f) => sum + f.sizeBytes, 0);
