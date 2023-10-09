-- cpu.vhd: Simple 8-bit CPU (BrainFuck interpreter)
-- Copyright (C) 2023 Brno University of Technology,
--                    Faculty of Information Technology
-- Author(s): jmeno <login AT stud.fit.vutbr.cz>
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_arith.all;
use ieee.std_logic_unsigned.all;

-- ----------------------------------------------------------------------------
--                        Entity declaration
-- ----------------------------------------------------------------------------
entity cpu is
 port (
   CLK   : in std_logic;  -- hodinovy signal
   RESET : in std_logic;  -- asynchronni reset procesoru
   EN    : in std_logic;  -- povoleni cinnosti procesoru
 
   -- synchronni pamet RAM
   DATA_ADDR  : out std_logic_vector(12 downto 0); -- adresa do pameti
   DATA_WDATA : out std_logic_vector(7 downto 0); -- mem[DATA_ADDR] <- DATA_WDATA pokud DATA_EN='1'
   DATA_RDATA : in std_logic_vector(7 downto 0);  -- DATA_RDATA <- ram[DATA_ADDR] pokud DATA_EN='1'
   DATA_RDWR  : out std_logic;                    -- cteni (0) / zapis (1)
   DATA_EN    : out std_logic;                    -- povoleni cinnosti
   
   -- vstupni port
   IN_DATA   : in std_logic_vector(7 downto 0);   -- IN_DATA <- stav klavesnice pokud IN_VLD='1' a IN_REQ='1'
   IN_VLD    : in std_logic;                      -- data platna
   IN_REQ    : out std_logic;                     -- pozadavek na vstup data
   
   -- vystupni port
   OUT_DATA : out  std_logic_vector(7 downto 0);  -- zapisovana data
   OUT_BUSY : in std_logic;                       -- LCD je zaneprazdnen (1), nelze zapisovat
   OUT_WE   : out std_logic;                      -- LCD <- OUT_DATA pokud OUT_WE='1' a OUT_BUSY='0'

   -- stavove signaly
   READY    : out std_logic;                      -- hodnota 1 znamena, ze byl procesor inicializovan a zacina vykonavat program
   DONE     : out std_logic                       -- hodnota 1 znamena, ze procesor ukoncil vykonavani programu (narazil na instrukci halt)
 );
end cpu;


-- ----------------------------------------------------------------------------
--                      Architecture declaration
-- ----------------------------------------------------------------------------
architecture behavioral of cpu is

-- SIGNALS
-- CNT REGISTER
  signal cnt_inc    :   std_logic;
  signal cnt_dec    :   std_logic;

-- PTR REGISTER
  signal ptr_inc    :   std_logic;
  signal ptr_dec    :   std_logic;
  signal ptr_reset  :   std_logic;
  signal ptr_addr   :   std_logic_vector(12 downto 0);

-- PC REGISTER
  signal pc_inc     :   std_logic;
  signal pc_dec     :   std_logic;
  signal pc_addr    :   std_logic_vector(12 downto 0);

-- MX1
  signal MX1_out    :   std_logic_vector(12 downto 0);
  signal MX1_select :   std_logic;

-- MX2
  signal MX2_out    :   std_logic_vector(7 downto 0);
  --signal MX2_in     :   std_logic_vector(7 downto 0);
  --signal MX2_inc    :   std_logic;
  --signal MX2_dec    :   std_logic;
  signal MX2_select :   std_logic_vector(1 downto 0);


-- FSM
  type fsm_state is ( s_init,
                      s_start, s_fetch, s_decode, -- FSM Operational states
                      s_ptr_inc, 
                      s_ptr_dec,       
                      s_val_inc0, s_val_inc1, s_val_inc2,
                      s_val_dec0, s_val_dec1, s_val_dec2,
                      s_loop_begin, 
                      s_loop_end, 
                      s_break,
                      s_write0, s_write1, 
                      s_read, 
                      s_end,
                      s_halt);

  signal pstate : fsm_state := s_start;
  signal nstate : fsm_state := s_start;

  begin
  -- PC REG PROCESS
    pc: process (CLK, RESET, pc_inc, pc_dec) is
      begin
        if (RESET = '1') then
          pc_addr <= (others => '0');
        elsif rising_edge(CLK) then
          if pc_inc = '1' then
            pc_addr <= pc_addr + 1;
          elsif pc_dec = '1' then
            pc_addr <= pc_addr - 1;
          end if;
        end if;
      end process;

    -- PTR REG PROCESS
    ptr: process (CLK, RESET, ptr_inc, ptr_dec, ptr_reset) is
      begin
        if (RESET = '1') then
          ptr_addr <= (others => '0');
        elsif rising_edge(CLK) then
          if ptr_inc = '1' then
            ptr_addr <= ptr_addr + 1;
          elsif ptr_dec = '1' then
            ptr_addr <= ptr_addr - 1;
          elsif ptr_reset = '1' then
            ptr_addr <= (others => '0');
          end if;
        end if;
      end process;

    -- MX1
    mx1: process (CLK, RESET, MX1_select, ptr_addr, pc_addr) is
      begin
        if (RESET = '1') then
          MX1_out <= (others => '0'); -- SHOULD BE OKAY
        elsif (MX1_select = '0') then
          MX1_out <= ptr_addr;
        elsif (MX1_select = '1') then
          MX1_out <= pc_addr;
        end if;
      end process;

    -- MX2 
    mx2: process (CLK, RESET, MX2_select) is
      begin
        if (RESET = '1') then
          MX2_out <= (others => '0');
        elsif rising_edge(CLK) then
          case MX2_select is
            when "00" =>
              MX2_out <= IN_DATA;
            when "01" =>
              MX2_out <= DATA_RDATA - 1;
            when "10" =>
              MX2_out <= DATA_RDATA + 1;
            when others => 
              MX2_out <= (others => '0');
          end case;
        end if;
      end process;
          

    -- FSM
    state_logic: process (CLK, RESET, EN) is
      begin
        if RESET = '1' then
          pstate <= s_init;
        elsif rising_edge(CLK) then
          if (EN = '1') then
            pstate <= nstate;
          end if;
        end if;
      end process;

    fsm: process (pstate, EN, OUT_BUSY, IN_VLD, DATA_RDATA, CLK)
      begin
        cnt_inc    <= '0';
        cnt_dec    <= '0';

        ptr_inc    <= '0';
        ptr_dec    <= '0';
        ptr_reset  <= '0';

        pc_inc     <= '0';
        pc_dec     <= '0';

        MX1_select <= '0';
        MX2_select <= "00";


        DATA_RDWR  <= '0';
        DATA_EN    <= '0';
        OUT_WE     <= '0';
        IN_REQ     <= '0';
        DONE       <= '0';

        case pstate is
          when s_init  =>
            DATA_EN <= '1';
            MX1_select <= '1';
            DATA_RDWR <= '0';
            DONE <= '0';
            READY <= '0';
            if DATA_RDATA = X"40" then 
              ptr_addr <= pc_addr; 
              nstate <= s_start;
            else
              pc_inc <= '1';
            end if;

          when s_start =>
            pc_addr <= (others => '0');
            nstate <= s_fetch;
          when s_fetch =>
            DATA_EN <= '1';
            MX1_select <= '1';
            DATA_RDWR <= '0';
            nstate <= s_decode;

          when s_decode =>
            case DATA_RDATA is
              when X"3E"  => -- ">"
                nstate <= s_ptr_inc;

              when X"3C"  => -- "<"
                nstate <= s_ptr_dec;

              when X"2B"  => -- "+"
                nstate <= s_val_inc0;

              when X"2D"  => -- "-"
                nstate <= s_val_dec0;

              when X"5B"  => -- "["
                nstate <= s_loop_begin;

              when X"5D"  => -- "]"
                nstate <= s_loop_end;

              when X"7E"  => -- "~"
                nstate <= s_break;

              when X"2E"  => -- "."
                nstate <= s_write0;

              when X"2C"  => -- ","
                nstate <= s_read;

              when X"40"  => -- "@"
                nstate <= s_end;

              when others =>
                nstate <= s_halt;
            end case;

          when s_ptr_inc    =>
            ptr_inc  <= '1';
            pc_inc   <= '1';
            nstate   <= s_fetch;

          when s_ptr_dec    =>
            ptr_dec  <= '1';
            pc_inc   <= '1';
            nstate   <= s_fetch;

          -- POINTER VALUE INCREASE
          when s_val_inc0   => -- ENABLE DATA, SET TO READ MODE, ADDR set to PTR
            DATA_EN <= '1';
            DATA_RDWR <= '0';
            MX1_select <= '0';
            nstate <= s_val_inc1;
          when s_val_inc1   => -- SET TO WRITE MODE
            DATA_RDWR <= '1';
            MX2_select <= "10";
            nstate <= s_val_inc2;
          when s_val_inc2   =>
            --MX2_out <= DATA_RDATA;
            pc_inc <= '1';
            nstate <= s_fetch; 

          -- POINTER VALUE DECREASE
          when s_val_dec0   =>
            DATA_EN <= '1';
             DATA_RDWR <= '0';
             MX1_select <= '0';
              nstate <= s_val_dec1;
          when s_val_dec1   =>
              DATA_RDWR <= '1';
              MX2_select <= "01";
              nstate <= s_val_dec2;
          when s_val_dec2   =>
              --DATA_ADDR <= DATA_RDATA - 1;
              nstate <= s_fetch;

          -- LOOPS
          when s_loop_begin =>
          when s_loop_end   =>
              if DATA_RDATA /= "00000000" then
              end if;
            
          when s_break      =>

          -- WRITE
          when s_write0     =>
            DATA_EN   <= '1';
            DATA_RDWR <= '0';
            OUT_WE  <= '1';
            MX1_select <= '0';
            nstate    <= s_write1;
          when s_write1     => 
            if OUT_BUSY = '1' then
              DATA_EN   <= '1';
              DATA_RDWR <= '0';
              OUT_WE  <= '1';
              nstate    <= s_write1;
            else
              OUT_DATA <= DATA_RDATA;
              pc_inc  <= '1';
              nstate <= s_fetch;
            end if;

          when s_read       =>
            
          when s_end       =>
            pc_addr <= pc_addr;
            DONE    <= '1';
          when s_halt       =>
              
          when others       =>
            pc_inc <= '1';
            nstate <= s_decode;
        end case;
      end process;

end behavioral;

