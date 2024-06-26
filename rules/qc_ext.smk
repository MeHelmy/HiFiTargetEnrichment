rule plot_read_categories:
    input:
        readCsv=f'batches/{batch}/stats/all_read_data.csv',
        lima=f'batches/{batch}/demux/demultiplex.lima.report',
        dups=f'batches/{batch}/stats/all_duplicate_lengths.csv',
    output:
        f'batches/{batch}/stats/read_categories.png',
        f'batches/{batch}/stats/read_length_by_sample.csv',
    params:
        odir=f'batches/{batch}/stats/'
    conda:
        'envs/python.yaml',
    script:
        'scripts/plot_read_cats.py'
    
# extand targets
targets.extend(
        [
            f'batches/{batch}/stats/{fname}'
            for fname in ['read_categories.png','read_length_by_sample.csv']
        ]
)
