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
  signal MX2_in     :   std_logic_vector(7 downto 0);
  signal MX2_inc    :   std_logic;
  signal MX2_dec    :   std_logic;
  signal MX2_select :   std_logic_vector(1 downto 0);


-- FSM
  type fsm_state is ( s_start, s_fetch, s_decode, -- FSM Operational states
                      s_ptr_inc, s_ptr_dec,       -- PTR Register states
                      s_val_inc, s_val_dec,       -- 
                      s_loop_begin, s_loop_end, 
                      s_break,
                      s_write, s_read, 
                      s_null)

  signal pstate : fsm_state :- s_start;
  signal nstate : fsm_state :- s_start;

  begin
  -- PC PROCESS
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

    -- PTR PROCESS
    ptr: process (CLK, RESET, ptr_inc, ptr_dec, ptr_reset) is
      begin
        if (RESET = '1') then
          ptr_addr <= (others => '0');
        elsif rising_edge(CLK) then
          if ptr_inc = '1' then
            ptr_addr <= ptr_addr + 1;
          elsif ptr_dec = '1' then
            ptr_addr <= ptr_addr - 1;
          elsif ptr_rst = '1' then
            ptr_addr <= (others => '0');
          end if;
        end if;
      end process;

    -- MX1
    mx1: process (CLK, RESET, MX1_select, ptr_addr, pc_addr) is
      begin
        if (RESET = '1') then
          MX1_out <= '0'; -- CHECK IF VALID
        elsif (MX1_select = '0') then
          DATA_ADDR <= ptr_addr;
        elsif (MX1_select = '1') then
          DATA_ADDR <= pc_addr;
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
            when others <= (others => '0');
          end case;
        end if;
      end process;
          


    -- FSM
    state_logic: process (CLK, RESET, EN) is
      begin
        if RESET = '1' then
          pstate <= s_start;
        elsif rising_edge(CLK) then
          pstate <= nstate;
        end if;
      end process;

    fsm: process (pstate, OUT_BUSY, IN_VLD, DATA_RDATA, CNT)
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

        case pstate is

          when s_start =>
            nstate <= s_fetch;

          when s_fetch =>
            EN <= '1';
            nstate <= s_decode;

          when s_decode =>
            case DATA_ADDR is
              when 0x3E => -- ">"
                nstate <= s_ptr_inc;
              when 0x3C => -- "<"
                nstate <= s_ptr_dec;
              when 0x2B => -- "+"
                nstate <= s_val_inc;
              when 0x2D => -- "-"
                nstate <= s_val_dec;
              when 0x5B => -- "["
                nstate <= s_loop_begin;
              when 0x5D => -- "]"
                nstate <= s_loop_end;
              when 0x7E => -- "~"
                nstate <= s_break;
              when 0x2E => -- "."
                nstate <= s_write;
              when 0x2C => -- ","
                nstate <= s_read;
              when 0x40 => -- "@"
                nstate <= s_null;
            end case;

          when s_ptr_inc    =>
          when s_ptr_dec    =>
          when s_val_inc    =>
          when s_val_dec    =>
          when s_loop_begin =>
          when s_loop_end   =>
          when s_break      =>
          when s_write      =>
          when s_read       =>
          when s_null       =>
        end case;
      end process;
          
    --fsm_pstate: process (RESET, CLK)
      --begin
        --if (RESET='1')
          --pstate <=



 -- pri tvorbe kodu reflektujte rady ze cviceni INP, zejmena mejte na pameti, ze 
 --   - nelze z vice procesu ovladat stejny signal,
 --   - je vhodne mit jeden proces pro popis jedne hardwarove komponenty, protoze pak
 --      - u synchronnich komponent obsahuje sensitivity list pouze CLK a RESET a 
 --      - u kombinacnich komponent obsahuje sensitivity list vsechny ctene signaly. 

end behavioral;

