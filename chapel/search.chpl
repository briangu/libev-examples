// BUG: declaring use IO, Memory here causes chpl compiler segv

module Search {
  
  use Logging, Memory, LockFreeHash, GenHashKey32, Partitions;

  config const sync_writers = false;
  config const entry_size: uint(32) = 1024*1024;

  // TODO: should be using a doc index that maps to a doc id?
  type DocId = uint(64);

  // for scoring and compactness purposes, consider making this use more contiguous memory,
  //  or an associative array(s) that use the score or docid as index.
  class Entry {
    var word: string;
    var score: real; // TODO: may not be needed if we use docCount as frequency
    var documentCount: atomic int;
    var documents: [0..8192-1] DocId; // TODO: point to the tail of a linked list; keep track of node + index into node
  }

  class PartitionIndex {
    var entryCount: atomic uint(32);
    var entryIndex = new LockFreeHash(entry_size);
    var entries: [1..entry_size] Entry;
    var writerLock: atomicflag;

    inline proc lockIndexWriter() {
      // debug("attempting to get lock");
      if (sync_writers) then while writerLock.testAndSet() do chpl_task_yield();
      // debug("have lock");
    }

    inline proc unlockIndexWriter() {
      // writeln("releasing lock");
      if (sync_writers) then writerLock.clear();
      // writeln("released lock");
    }

    proc PartitionIndex() {
      entryCount.add(1); // start at the first index of entries
    }
  }

  var Indices: [0..Partitions.size-1] PartitionIndex;

  proc initIndices() {
    for i in 0..Partitions.size-1 {
      on Partitions[i] {
        info("index [", i, "] is mapped to partition ", i);
  
        // allocate the partition index on the partition locale
        Indices[i] = new PartitionIndex();
      }
    }
  }

  proc entryForWord(word: string): Entry {
    var partition = partitionForWord(word);
    var partitionIndex = Indices[partition];
    var entry: Entry;
    on partitionIndex {
      entry = entryForWordOnPartition(word, partitionIndex);
    }
    return entry;
  }

  proc entryForWordOnPartition(word: string, partitionIndex: PartitionIndex): Entry {
    var entryIndex = entryIndexForWord(word, partitionIndex);
    if (entryIndex > 0) {
      return partitionIndex.entries[entryIndex];
    }
    return nil;
  }

  proc indexWord(word: string, docid: DocId) {
    var partition = partitionForWord(word);
    var partitionIndex = Indices[partition];
    on partitionIndex {
      partitionIndex.lockIndexWriter();

      var entry = entryForWordOnPartition(word, partitionIndex);
      if (entry != nil) {
        info("adding ", word, " to existing entries on partition ", partition);
        var docCount = entry.documentCount.read();
        if (docCount < entry.documents.size) {
          entry.documents[docCount] = docid;
          entry.documentCount.add(1);
        } else {
          // TODO: append node to linked list of document ids
          info("TODO: realloc documents");
        }
      } else {
        info("adding new entry ", word , " on partition ", partition);

        var entriesCount = partitionIndex.entryCount.read();
        if (entriesCount < partitionIndex.entries.size) {
          entry = new Entry();
          entry.word = word;
          entry.score = 0;        
          entry.documents[0] = docid;
          entry.documentCount.add(1);

          var entryIndex: uint(32) = partitionIndex.entryCount.fetchAdd(1);
          partitionIndex.entries[entryIndex] = entry;
          var success = partitionIndex.entryIndex.setItem(word, entryIndex);
          if (!success) {
            writeln("indexWord: failed to index ", word);
            exit(0);
            // how do we accumuate per-partition indexing errors for a final response?
          }
        }
      }

      partitionIndex.unlockIndexWriter();
    }
  }

  proc indexContainsWord(word: string, partitionIndex: PartitionIndex): bool {
    return entryIndexForWord(word, partitionIndex) != 0;
  }

  proc entryIndexForWord(word: string, partitionIndex: PartitionIndex): uint(32) {
    return partitionIndex.entryIndex.getItem(word);
  }

  proc dumpEntry(entry: Entry) {
    on entry {
      writeln("word: ", entry.word, " score: ", entry.score);
      for i in 0..entry.documentCount.read()-1 {
        writeln("\t", entry.documents[i]);
      }
    }
  }

  proc dumpPartition(partition: int) {
    var partitionIndex = Indices[partition];
    on partitionIndex {
      writeln("entries on partition (", partition, ") locale (", here.id, ") ", partitionIndex.entries);

      var word: string;
      for i in 0..partitionIndex.entryCount.read()-1 {
        var entry = partitionIndex.entries[i];
        writeln("word: ", entry.word);
        dumpPostingTableForWord(entry.word);
      }
    }
  }

  proc dumpPostingTableForWord(word: string) {
    var partition = partitionForWord(word);
    var partitionIndex = Indices[partition];
    on partitionIndex {
      var entryIndex = entryIndexForWord(word, partitionIndex);
      if (entryIndex > 0) {
        dumpEntry(partitionIndex.entries[entryIndex]);
      } else {
        writeln("word (", word, ") is not in the index");
      }
    }
  }
}
