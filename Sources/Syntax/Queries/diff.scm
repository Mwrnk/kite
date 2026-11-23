; Based on tree-sitter-grammars/tree-sitter-diff. File names and +/- signs keep their line's color.

(comment) @comment

[
  (addition)
  (new_file)
] @diff.plus

[
  (deletion)
  (old_file)
] @diff.minus

(change) @constant

(commit) @constant

(location) @keyword

(command) @keyword

(mode) @number

[
  (binary_change)
  (similarity)
  (dissimilarity)
  (file_change)
] @label

(index
  "index" @keyword)

(similarity
  (score) @number
  "%" @number)

(dissimilarity
  (score) @number
  "%" @number)

(binary_hunk
  [
    "literal"
    "delta"
  ] @keyword
  (size) @number)
