import os
import shutil
import xbmc

def translatePath(path):
    return xbmc.translatePath(path)

def exists(path):
    return os.path.exists(translatePath(path))

def mkdirs(path):
    os.makedirs(translatePath(path), exist_ok=True)
    return True

mkdir = mkdirs

def delete(path):
    p = translatePath(path)
    if os.path.exists(p):
        os.remove(p)
        return True
    return False

def copy(source, destination):
    shutil.copy2(translatePath(source), translatePath(destination))
    return True

class File:
    def __init__(self, filepath, type=""):
        self._path = translatePath(filepath)
        mode = "wb" if "w" in type else "rb"
        os.makedirs(os.path.dirname(self._path), exist_ok=True)
        self._f = open(self._path, mode)

    def read(self, numBytes=0):
        data = self._f.read(numBytes) if numBytes else self._f.read()
        return data.decode("utf-8", errors="ignore")

    def readBytes(self, numBytes=0):
        return self._f.read(numBytes) if numBytes else self._f.read()

    def write(self, buffer):
        if isinstance(buffer, str):
            buffer = buffer.encode("utf-8")
        self._f.write(buffer)
        return True

    def close(self):
        self._f.close()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


def listdir(path):
    import os
    p = translatePath(path)
    if os.path.isdir(p):
        return os.listdir(p), []
    return [], []


mkdir = mkdirs
