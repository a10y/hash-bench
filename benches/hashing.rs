use divan::{Bencher, black_box, counter::BytesCount};
use sha2::{Digest, Sha256};

fn main() {
    divan::main();
}

fn block_sizes() -> impl Iterator<Item = usize> {
    (4..=20).map(|power| 1 << power)
}

#[divan::bench(args = block_sizes(), threads = 1)]
fn blake3(bencher: Bencher, size: usize) {
    // Allocate and fill the input before timing starts.
    let input = vec![0xA5; size];
    bencher
        .counter(BytesCount::new(size))
        .with_inputs(blake3::Hasher::new)
        .bench_local_values(|mut hasher| {
            hasher.update(black_box(input.as_slice()));
            black_box(hasher.finalize());
        });
}

#[divan::bench(args = block_sizes(), threads = 1)]
fn sha256(bencher: Bencher, size: usize) {
    // Allocate and fill the input before timing starts.
    let input = vec![0xA5; size];
    // Create each hash state before timing starts.
    bencher
        .counter(BytesCount::new(size))
        .with_inputs(Sha256::new)
        .bench_local_values(|mut hasher| {
            hasher.update(black_box(input.as_slice()));
            black_box(hasher.finalize());
        });
}
