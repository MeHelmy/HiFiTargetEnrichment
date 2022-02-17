ruleorder: samtools_fasta > seqtk_fastq_to_fasta


rule samtools_fasta:
    input:
        lambda wildcards: f'batches/{batch}/{{sample}}/dedup/deduplicated.{sample2barcode[wildcards.sample]}.bam',
    output: 
        f"batches/{batch}/{{sample}}/fasta/{{sample}}.fasta"
    log: 
        f"batches/{batch}/logs/samtools/fasta/{{sample}}.log"
    threads: 4
    conda: 
        "envs/samtools.yaml"
    message: 
        "Converting {input} to {output}."
    shell: 
        "(samtools fasta -@ 3 {input} > {output}) > {log} 2>&1"


rule seqtk_fastq_to_fasta:
    input:
        lambda wildcards: f'batches/{batch}/{{sample}}/dedup/deduplicated.{sample2barcode[wildcards.sample]}.fastq',
    output: 
        f"batches/{batch}/{{sample}}/fasta/{{sample}}.fasta"
    log: 
        f"batches/{batch}/logs/seqtk/seq/{{sample}}.log"
    conda: 
        "envs/seqtk.yaml"
    message: 
        "Converting {input} to {output}."
    shell: 
        "(seqtk seq -A {input} > {output}) > {log} 2>&1"


rule hifiasm_assemble:
    input: 
        f"batches/{batch}/{{sample}}/fasta/{{sample}}.fasta",
    output:
        f"batches/{batch}/{{sample}}/hifiasm/{{sample}}.asm.bp.hap1.p_ctg.gfa",
        f"batches/{batch}/{{sample}}/hifiasm/{{sample}}.asm.bp.hap1.p_ctg.lowQ.bed",
        f"batches/{batch}/{{sample}}/hifiasm/{{sample}}.asm.bp.hap1.p_ctg.noseq.gfa",
        f"batches/{batch}/{{sample}}/hifiasm/{{sample}}.asm.bp.hap2.p_ctg.gfa",
        f"batches/{batch}/{{sample}}/hifiasm/{{sample}}.asm.bp.hap2.p_ctg.lowQ.bed",
        f"batches/{batch}/{{sample}}/hifiasm/{{sample}}.asm.bp.hap2.p_ctg.noseq.gfa",
        f"batches/{batch}/{{sample}}/hifiasm/{{sample}}.asm.bp.p_ctg.gfa",
        f"batches/{batch}/{{sample}}/hifiasm/{{sample}}.asm.bp.p_utg.gfa",
        f"batches/{batch}/{{sample}}/hifiasm/{{sample}}.asm.bp.r_utg.gfa",
        #f"batches/{batch}/{{sample}}/hifiasm/{{sample}}.asm.ec.bin",
        #f"batches/{batch}/{{sample}}/hifiasm/{{sample}}.asm.ovlp.reverse.bin",
        #f"batches/{batch}/{{sample}}/hifiasm/{{sample}}.asm.ovlp.source.bin"
    log: 
        f"batches/{batch}/logs/hifiasm/{{sample}}.log"
    benchmark: 
        f"batches/{batch}/benchmarks/{{sample}}.hifiasm.tsv"
    conda: 
        "envs/hifiasm.yaml"
    params: 
        prefix = f"batches/{batch}/{{sample}}/hifiasm/{{sample}}.asm"
    threads: 24
    message: 
        "Assembling sample {wildcards.sample} from {input}"
    shell: 
        "(hifiasm -o {params.prefix} -t {threads} {input}) > {log} 2>&1"


rule gfa2fa:
    input: 
        f"batches/{batch}/{{sample}}/hifiasm/{{sample}}.asm.bp.{{infix}}.gfa"
    output: 
        f"batches/{batch}/{{sample}}/hifiasm/{{sample}}.asm.bp.{{infix}}.fasta"
    log: 
        f"batches/{batch}/logs/gfa2fa/{{sample}}.asm.bp.{{infix}}.log"
    benchmark: 
        f"batches/{batch}/benchmarks/gfa2fa/{{sample}}.asm.bp.{{infix}}.tsv"
    conda: 
        "envs/gfatools.yaml"
    message: 
        "Extracting fasta from assembly {input}."
    shell: 
        "(gfatools gfa2fa {input} > {output}) 2> {log}"


rule bgzip_fasta:
    input: 
        f"batches/{batch}/{{sample}}/hifiasm/{{sample}}.asm.bp.{{infix}}.fasta"
    output:
         f"batches/{batch}/{{sample}}/hifiasm/{{sample}}.asm.bp.{{infix}}.fasta.gz"
    log: 
        f"batches/{batch}/logs/bgzip/{{sample}}.asm.bp.{{infix}}.log"
    benchmark: 
        f"batches/{batch}/benchmarks/bgzip/{{sample}}.asm.bp.{{infix}}.tsv"
    threads: 4
    conda: 
        "envs/htslib.yaml"
    message: 
        "Compressing {input}."
    shell: 
        "(bgzip --threads {threads} {input}) > {log} 2>&1"


rule asm_stats:
    input: 
        f"batches/{batch}/{{sample}}/hifiasm/{{sample}}.asm.bp.{{infix}}.fasta.gz"
    output: 
        f"batches/{batch}/{{sample}}/hifiasm/{{sample}}.asm.bp.{{infix}}.fasta.stats.txt"
    params:
        faidx=config['ref']['index']
    log: 
        f"batches/{batch}/logs/asm_stats/{{sample}}.asm.bp.{{infix}}.fasta.log"
    benchmark: 
        f"batches/{batch}/benchmarks/asm_stats/{{sample}}.asm.bp.{{infix}}.fasta.tsv"
    conda: 
        "envs/k8.yaml"
    message: 
        "Calculating stats for {input}."
    shell: 
        '''
        (k8 workflow/scripts/calN50/calN50.js -f {params.faidx} {input} > {output}) > {log} 2>&1
        '''


rule align_hifiasm:
    input:
        target = config['ref']['fasta'],
        query = [
                    f"batches/{batch}/{{sample}}/hifiasm/{{sample}}.asm.bp.{infix}.fasta.gz"
                    for infix in ["hap1.p_ctg", "hap2.p_ctg"]
                ],
    output: 
        f"batches/{batch}/{{sample}}/hifiasm/{{sample}}.asm.{ref}.bam"
    log: 
        f"batches/{batch}/logs/align_hifiasm/{{sample}}.asm.{ref}.log"
    benchmark: 
        f"batches/{batch}/benchmarks/align_hifiasm/{{sample}}.asm.{ref}.tsv"
    params:
        max_chunk = 200000,
        minimap2_args = "-L --secondary=no --eqx -ax asm5",
        minimap2_threads = 10,
        readgroup = "@RG\\tID:{sample}_hifiasm\\tSM:{sample}",
        samtools_threads = 3
    threads: 16  # minimap2 + samtools(+1) + 2x awk + seqtk + cat
    conda: 
        "envs/align_hifiasm.yaml"
    message: 
        "Aligning {input.query} to {input.target}."
    shell:
        """
        (cat {input.query} \
            | seqtk seq -l {params.max_chunk} - \
            | awk '{{ if ($1 ~ />/) {{ n=$1; i=0; }} else {{ i++; print n "." i; print $0; }} }}' \
            | minimap2 -t {params.minimap2_threads} {params.minimap2_args} \
                -R '{params.readgroup}' {input.target} - \
                | awk '{{ if ($1 !~ /^@/) \
                                {{ Rct=split($1,R,"."); N=R[1]; for(i=2;i<Rct;i++) {{ N=N"."R[i]; }} print $0 "\tTG:Z:" N; }} \
                              else {{ print; }} }}' \
                | samtools sort -@ {params.samtools_threads} > {output}) > {log} 2>&1
        """

rule samtools_index_bam:
    input:
        f"batches/{batch}/{{sample}}/hifiasm/{{sample}}.asm.{ref}.bam"
    output:
        f"batches/{batch}/{{sample}}/hifiasm/{{sample}}.asm.{ref}.bam.bai",
    log:
        f"batches/{batch}/logs/samtools/index/{{sample}}.asm.{ref}.bam.log"
    threads: 4
    conda:
        "envs/samtools.yaml"
    message:
        "Executing {rule}: Indexing {input}."
    shell:
        '''
        (samtools index -@ 3 {input}) > {log} 2>&1
        '''

rule htsbox:
    input:
        bam = f"batches/{batch}/{{sample}}/hifiasm/{{sample}}.asm.{ref}.bam",
        bai = f"batches/{batch}/{{sample}}/hifiasm/{{sample}}.asm.{ref}.bam.bai",
        reference = config['ref']['fasta'],
    output: 
        f"batches/{batch}/{{sample}}/hifiasm/{{sample}}.asm.{ref}.htsbox.vcf"
    log: 
        f"batches/{batch}/logs/htsbox/{{sample}}.asm.log"
    benchmark: 
        f"batches/{batch}/benchmarks/htsbox/{{sample}}.asm.tsv"
    params: 
        '-q20'
    conda: 
        "envs/htsbox.yaml"
    message: 
        "Calling variants from {input.bam} using htsbox."
    shell: 
        '''
        (htsbox pileup {params} -c -f {input.reference} {input.bam} > {output})> {log} 2>&1
        '''

rule bgzip_vcf:
    input:
        f"batches/{batch}/{{sample}}/hifiasm/{{sample}}.asm.{ref}.htsbox.vcf",
    output:
        f"batches/{batch}/{{sample}}/hifiasm/{{sample}}.asm.{ref}.htsbox.vcf.gz",
    log:
        f"batches/{batch}/logs/bgzip/{{sample}}.asm.{ref}.htsbox.log",
    threads: 2
    conda:
        "envs/htslib.yaml"
    message:
        "Executing {rule}: Compressing {input}."
    shell:
        "(bgzip --threads {threads} {input}) > {log} 2>&1"


rule htsbox_bcftools_stats:
    input: 
        f"batches/{batch}/{{sample}}/hifiasm/{{sample}}.asm.{ref}.htsbox.vcf.gz"
    output: 
        f"batches/{batch}/{{sample}}/hifiasm/{{sample}}.asm.{ref}.htsbox.vcf.stats.txt"
    log: 
        f"batches/{batch}/logs/bcftools/stats/{{sample}}.asm.{ref}.htsbox.vcf.log"
    benchmark: 
        f"batches/{batch}/benchmarks/bcftools/stats/{{sample}}.asm.{ref}.htsbox.vcf.tsv"
    params: 
        f"--fasta-ref {config['ref']['fasta']} -s batches/{batch}/{{sample}}/hifiasm/{{sample}}.asm.{ref}.bam"
    threads: 4
    conda: 
        "envs/bcftools.yaml"
    message: 
        "Executing {rule}: Calculating VCF statistics for {input}."
    shell: 
        '''
        (bcftools stats --threads 3 {params} {input} > {output}) > {log} 2>&1
        '''