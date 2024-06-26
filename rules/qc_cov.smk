localrules: 
    merge_read_metrics,
    consolidate_read_data,
    count_issue_elements,
    get_coverage_fraction,
    create_exons_bed,
    copy_beds,

allBeds = ['targets','exons']

rule create_exons_bed:
    input:
        ensmbl=config['ref']["exons"],
        targets=config['targets'],
    output:
        temp(f'batches/{batch}/beds/exons.bed'),
    conda:
        "envs/samtools.yaml"
    message:
        "Generate bed of exons within target regions for qc"
    log:
        f'batches/{batch}/logs/bedtools/exon.bed.log'
    shell:
        '''
        (bedtools intersect -u -a {input.ensmbl} -b {input.targets} > {output}) > {log} 2>&1
        '''

rule copy_beds:
    input:
        lambda wildcards: config[ wildcards.elem ],
    output:
        temp( f'batches/{batch}/beds/{{elem}}.bed' ),
    message:
        "Copy beds for pipeline naming consistency"
    shell:
        '''
        cp {input} {output}
        '''

rule count_ontarget:
    input:
        bed=lambda wildcards: f'batches/{batch}/beds/{wildcards.bedfile}.bed',
        bam=f"batches/{batch}/{{sample}}/aligned/{{sample}}.{ref}.bam",
    output:
        filtered=temp(f'batches/{batch}/{{sample}}/counts/readcount_{{bedfile}}.bam'),
        by_elem=temp(f'batches/{batch}/{{sample}}/counts/readcount_{{bedfile}}.bed'),
        by_read=temp(f'batches/{batch}/{{sample}}/counts/{{bedfile}}_per_read.csv'),
    params:
        elem='{bedfile}',
        filter=3328,  #not prim,not supp, not dup
    conda:
        "envs/samtools.yaml"
    message:
        "Counting intersections of {wildcards.bedfile} with {input.bam}"
    shell:
        '''
        samtools view -hbF {params.filter} {input.bam} > {output.filtered}
        #by element count of reads
        bedtools intersect -a {input.bed} -b {output.filtered} -c > {output.by_elem}
        #by read count of elements
        bedtools intersect -a {output.filtered} -b {input.bed} -bed -c \
        | awk -v elem={params.elem} \
              'BEGIN {{ OFS="," ; print "readname,chr,start,stop,"elem }} \
               {{ print $4,$1,$2,$3,$NF }}' \
        | ( sed -u 1q; sort ) > {output.by_read} 
        '''

rule get_coverage:
    input:
        bed=lambda wildcards: f'batches/{batch}/beds/{wildcards.bedfile}.bed',
        bam=f"batches/{batch}/{{sample}}/aligned/{{sample}}.{ref}.bam",
    output:
        ontarget=temp(f'batches/{batch}/{{sample}}/coverage/{{bedfile}}_ontarget.bam'),
        bg=f'batches/{batch}/{{sample}}/coverage/{{bedfile}}_coverage.bedgraph',
        cov=f'batches/{batch}/{{sample}}/coverage/{{bedfile}}_base_coverage.csv',
    params:
        sample='{sample}',
        filter=3328,
    conda:
        "envs/samtools.yaml"
    message:
        "Getting coverage of {input.bed} from {input.bam}"
    log:
        f'batches/{batch}/logs/bedtools/get_coverage.{{bedfile}}.{{sample}}.bed.log'
    shell:
        '''
        bedtools intersect -a <(samtools view -hbF {params.filter} {input.bam}) -b {input.bed} > {output.ontarget}
        bedtools genomecov -bga -ibam {output.ontarget} > {output.bg}
        bedtools intersect -a {output.bg} -b {input.bed} -wb \
        | awk -v s={params.sample} \
              'BEGIN {{ OFS = ","; print "sample,chr,start,stop,coverage,target" }} \
              {{ print s,$1,$2,$3,$4,$8 }}' \
        > {output.cov} 
        '''

rule get_coverage_fraction:
    input:
        f'batches/{batch}/{{sample}}/coverage/{{bedfile}}_base_coverage.csv',
    output:
        f'batches/{batch}/{{sample}}/coverage/{{bedfile}}_base_coverage_fraction.csv',
    params:
        sample='{sample}',
        lowcov=config["QC"]["lowcov"],
    log:
        f'batches/{batch}/logs/awk/coverage_fraction.{{bedfile}}.{{sample}}.bed.log'
    shell:
        '''
        awk -F, -v s={params.sample} -v low={params.lowcov} \
            'BEGIN {{ OFS=","; print "sample,target,totalBp,lowcovBp,fracLow" }} 
             NR>1 {{ 
                    span = $4 - $3; 
                    split( $6, t, "_" ); target = t[1];
                    total += span; 
                    subset[target] += span; 
                    if( $5 <= low ) {{ 
                                        lowcov += span; 
                                        lowsubset[target] += span; 
                                      }} 
                   }} 
             END {{ 
                    for ( tg in subset ) {{ print s, tg, subset[tg], lowsubset[tg], lowsubset[tg]/subset[tg]; }} 
                    print s,"all",total,lowcov,lowcov/total; 
                 }}' {input} > {output}
        '''

rule summarize_coverage_fraction:
    input:
        lambda wildcards: 
                [ f'batches/{batch}/{sample}/coverage/{{bedfile}}_base_coverage_fraction.csv' 
                  for sample in _get_demuxed_samples( wildcards ) ]
    output:
        f'batches/{batch}/stats/{{bedfile}}_covered_fraction.csv',
    log:
        f'batches/{batch}/logs/awk/summarize_coverage_fraction.{{bedfile}}.bed.log'
    shell:
        '''
        tail -qn1 {input} \
        | awk -F, \
            'BEGIN {{ OFS=","; print "sample,target,totalBp,lowcovBp,fracLow" }} \
            {{ \
                total += $3; \
                lowcov += $4; \
                print; \
            }} \
            END {{ \
                    print "Total","allTargets",total,lowcov,lowcov/total;
                }}' \
        > {output}
        '''

rule get_read_metrics:
    input:
        bam=f"batches/{batch}/{{sample}}/aligned/{{sample}}.{ref}.bam",
    output:
        stats=temp(f'batches/{batch}/{{sample}}/read_metrics/reads.csv'),
    params:
        filter=3328,
    conda:
        "envs/samtools.yaml",
    message:
        "Getting samtools target read metrics from {input.bam}"
    shell:
        '''
        samtools view -F {params.filter} {input.bam} \
        | awk 'BEGIN {{ OFS="," ; print "readname,length,qual,ismapped,duplicates,softclip" }} \
               {{ if( match( $0, /ds:i:[0-9]/ ) ) {{ split( substr( $0, RSTART, RLENGTH ),d,":"); dup=d[3] }} \
                  else                            {{ dup=0 }} \
               }} ; \
               {{ soft = match( $6, /[0-9]+S/ ) ? \
                         substr( $6, RSTART, RLENGTH-1 ) : \
                         0 \
               }} ; \
               {{ mapped = !and($2,4) }} ; \
               {{ match( $0, /rq:f:[0-9.]+/ ); \
                  split( substr( $0, RSTART, RLENGTH ),q,":") ; \
                  print $1, length($10), q[3], mapped, dup, soft \
               }}' \
        | ( sed -u 1q; sort) > {output.stats}
        '''

rule get_read_target_metrics:
    input:
        bed=config['targets'],
        bam=f"batches/{batch}/{{sample}}/aligned/{{sample}}.{ref}.bam",
    output:
        target=temp(f'batches/{batch}/{{sample}}/read_metrics/read_target.csv'),
    params:
        filter=3328,
    conda:
        "envs/samtools.yaml",
    message:
        "Getting target read metrics from {input.bam}"
    shell:
        ''' 
        bedtools intersect -a <(samtools view -hbF {params.filter} {input.bam}) -b {input.bed} -bed -loj \
        | awk 'BEGIN {{ print "readname,target" }} \
               {{ print $4","$NF }}' \
        | ( sed -u 1q; sort -t, -u -k1,1 ) > {output.target}
        ''' 

rule get_duplicate_lengths:
    input:
        f"batches/{batch}/{{sample}}/aligned/{{sample}}.{ref}.bam",
    output:
        temp(f'batches/{batch}/{{sample}}/read_metrics/duplicate_lengths.csv'),
    params:
        sample='{sample}'
    message:
        "Getting duplicate readlengths for {input}"
    conda:
        "envs/samtools.yaml",
    shell:
        '''
        samtools view -f 1024 {input} \
        | awk -v s={params.sample} '{{print s","length($10)",Duplicates"}}' \
        > {output}
        '''

rule merge_duplengths:
    input:
        lambda wildcards:
            [ f'batches/{batch}/{sample}/read_metrics/duplicate_lengths.csv'
              for sample in _get_demuxed_samples( wildcards ) ]
    output:
        temp(f'batches/{batch}/stats/all_duplicate_lengths.csv'),
    shell:
        ''' 
        awk ' BEGIN {{ print "sample,length,category" }}
              {{ print }}' {input} > {output}
        '''

rule merge_read_metrics:
    input:
        f'batches/{batch}/{{sample}}/read_metrics/reads.csv',
        f'batches/{batch}/{{sample}}/read_metrics/read_target.csv',
        f'batches/{batch}/{{sample}}/counts/exons_per_read.csv',
    output:
        temp( f'batches/{batch}/{{sample}}/read_metrics/read_data.csv' ),
    params:
        sample='{sample}'
    conda:
        'envs/python.yaml'
    script:
        'scripts/merge_read_metrics.py'

rule consolidate_read_data:
    input: 
        lambda wildcards:
            [ f'batches/{batch}/{sample}/read_metrics/read_data.csv'
              for sample in _get_demuxed_samples( wildcards ) ]
    output:
        f'batches/{batch}/stats/all_read_data.csv',
    shell:
        '''
        awk 'NR==1 || FNR>1' {input} > {output}
        '''

rule consolidate_coverage:
    input:
        lambda wildcards:
            [ f'batches/{batch}/{sample}/coverage/{{bedfile}}_base_coverage.csv'
              for sample in _get_demuxed_samples( wildcards ) ]
    output:
        f'batches/{batch}/stats/all_{{bedfile}}_coverage.csv',
    shell:
        '''
        awk 'NR==1 || FNR>1' {input} > {output}
        '''

rule count_issue_elements:
    input:
        lambda wildcards:
            [ f'batches/{batch}/{sample}/counts/readcount_{{elem}}.bed'
              for sample in _get_demuxed_samples( wildcards ) ]
    output:
        f'batches/{batch}/stats/{{status}}/{{elem}}.csv',
    params:
        low= lambda wildcards: 0 if wildcards.status == 'dropped' else config['QC']['lowcov']
    shell:
        '''
        awk -v min={params.low} '$NF <= min {{ print $1, $2, $3, $4 ~ /^[0-9]+$/ ? "" : $4 }}' {input} \
        | sort -k1,1 -k2,2n \
        | uniq -c \
        | awk 'BEGIN {{ OFS=","; print "chr,start,stop,target,samplesDropped" }} \
                     {{ print $2,$3,$4,$5,$1 }}' \
        > {output}
        '''

rule gc_content:
    input:
        bed=lambda wildcards: f'batches/{batch}/beds/{wildcards.bedfile}.bed',
        ref=config["ref"]["fasta"],
    output:
        f'batches/{batch}/stats/{{bedfile}}_frac_gc.csv',
    conda:
        "envs/samtools.yaml"
    shell:
        '''
        bedtools nuc -fi {input.ref} -bed {input.bed} \
        | awk 'BEGIN {{ OFS=","; print "chr,start,stop,target,frac_gc" }} \
               NR>1  {{ print $1,$2,$3,$4,$(NF-7) }}' \
        > {output}
        '''

rule plot_read_metrics:
    input:
        csv=f'batches/{batch}/{{sample}}/read_metrics/read_data.csv',
        bed=config['targets'],
    output:
        [f'batches/{batch}/{{sample}}/read_metrics/{p}' 
          for p in 
            ['mean_base_coverage_by_target.png',
             'readlength_hist.png',
             'readlength_hist_by_target.png',
             'readlength_violins_by_target.png',
             'dedup_count_by_target.png',
             'dedup_rate_by_target.png',
             'readqual_by_target.png',
             'off-target_length_hist.png'
            ]
        ],
    params:
        odir=f'batches/{batch}/{{sample}}/read_metrics',
        buffer=5000,
    conda:
        'envs/python.yaml',
    script:
        'scripts/plot_read_data.py'

rule plot_coverage:
    input:
        f'batches/{batch}/{{sample}}/coverage/targets_base_coverage.csv',
    output:
        f'batches/{batch}/{{sample}}/coverage/coverage_by_target.png',
    params:
        odir=f'batches/{batch}/{{sample}}/coverage',
    conda:
        'envs/python.yaml',
    script:
        'scripts/plot_coverage.py'

rule plot_multi_coverage:
    input:
        f'batches/{batch}/stats/all_targets_coverage.csv',
    output:
        f'batches/{batch}/stats/multi_coverage_by_target.png',
    params:
        odir=f'batches/{batch}/stats',
    conda:
        'envs/python.yaml',
    script:
        'scripts/plot_multi_coverage.py'

rule plot_multi_read:
    input:
        csv=f'batches/{batch}/stats/all_read_data.csv',
        bed=config['targets'],
    output:
        [
          f'batches/{batch}/stats/{p}' 
          for p in
            ['mean_base_coverage.png',
             'mean_base_coverage_by_sample.png',
             'dedup_length_by_target.png',
             'dedup_rate_by_target.png',
             'readlength_hist_by_target.png'
            ]
        ],
    params:
        odir=f'batches/{batch}/stats',
        buffer=f'{config["picard"]["near_distance"]}',
        targetsPerPanel=25,
    conda:
        'envs/python.yaml',
    script:
        'scripts/plot_multi_reads.py'



targets.append(
    lambda wildcards: 
        [
            f'batches/{batch}/{sample}/counts/readcount_{bedfile}.bed'
            for sample in _get_demuxed_samples( wildcards )
            for bedfile in allBeds
        ]
)

targets.append(
    lambda wildcards:
        [
            f'batches/{batch}/{sample}/counts/{bedfile}_per_read.csv'
            for sample in _get_demuxed_samples( wildcards )
            for bedfile in allBeds
        ]
)

targets.append(
    lambda wildcards:
        [
            f'batches/{batch}/{sample}/read_metrics/reads.csv'
            for sample in _get_demuxed_samples( wildcards )
        ]
)

targets.append(
    lambda wildcards:
        [
            f'batches/{batch}/{sample}/read_metrics/read_data.csv'
            for sample in _get_demuxed_samples( wildcards )
        ]
)

targets.extend(
        [
            f'batches/{batch}/stats/{bedfile}_frac_gc.csv'
            for bedfile in allBeds
        ]
)

targets.extend(
        [
            f'batches/{batch}/stats/all_{bedfile}_coverage.csv'
            for bedfile in allBeds
        ]
)

targets.append(
    lambda wildcards:
        [
            f'batches/{batch}/{sample}/read_metrics/mean_base_coverage_by_target.png'
            for sample in _get_demuxed_samples( wildcards )
        ]
)

targets.append(
    lambda wildcards:
        [
            f'batches/{batch}/{sample}/coverage/coverage_by_target.png'
            for sample in _get_demuxed_samples( wildcards )
        ]
)

targets.extend(
        [
            f'batches/{batch}/stats/{status}/{elem}.csv'
            for status in ['dropped','lowcov']
            for elem in allBeds
        ]
)

targets.append(
    lambda wildcards:
        [
            f'batches/{batch}/{sample}/coverage/{bedfile}_base_coverage_fraction.csv'
            for sample in _get_demuxed_samples( wildcards )
            for bedfile in allBeds
        ]
)

targets.extend(
        [
            f'batches/{batch}/stats/{bedfile}_covered_fraction.csv'
            for bedfile in allBeds
        ]
)

targets.extend(
        [
            f'batches/{batch}/stats/all_read_data.csv',
            f'batches/{batch}/stats/mean_base_coverage.png',
            f'batches/{batch}/stats/multi_coverage_by_target.png',
            f'batches/{batch}/stats/all_duplicate_lengths.csv'
        ]
)

targets.append(
    lambda wildcards:
        [
            f'batches/{batch}/{sample}/read_metrics/duplicate_lengths.csv'
            for sample in _get_demuxed_samples( wildcards )
        ]
)
